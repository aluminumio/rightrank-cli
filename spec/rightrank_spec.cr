require "spec"
require "athena-console/spec"
require "../src/rightrank"

Colorize.enabled = false
REQUESTS = [] of String

def fixture(name : String) : String
  File.read("#{__DIR__}/fixtures/#{name}.json")
end

# Serves the fixture of the first matching path prefix; any other path is a 404.
def stub(routes : Hash(String, String), status = 200, headers = HTTP::Headers{"X-Total-Count" => "3"})
  REQUESTS.clear
  RightRank.fetch = ->(path : String) do
    REQUESTS << path
    key = routes.keys.find { |k| path.starts_with? k }
    return HTTP::Client::Response.new(status, fixture(routes[key]), headers) if key
    path.includes?('?') ? HTTP::Client::Response.new(200, "[]") : HTTP::Client::Response.new(404, %({"error":"Unknown model: x"}))
  end
end

def run(input : Hash(String, _)) : {ACON::Command::Status, String}
  app = RightRank.app
  app.auto_exit = false
  tester = ACON::Spec::ApplicationTester.new(app)
  {tester.run(input, decorated: false), tester.display}
end

describe RightRank do
  it "ranks a dimension, with hyphens, cost and value" do
    stub({"/rankings/long-context" => "rankings_coding"})
    status, out = run({"command" => "leaderboard", "--dimension" => "Long Context", "--limit" => "2"})
    status.should eq ACON::Command::Status::SUCCESS
    REQUESTS.should eq ["/rankings/long-context?limit=2"]
    out.lines.first.should eq "#  Model                                  Provider   Score  Price                 Value"
    out.should contain "1  Gemini 3 Pro Preview (high)            Google     100.0  $2.00 / $12.00 per M  7.1"
  end

  it "ranks a benchmark by raw score" do
    stub({"/benchmarks/livecodebench/leaderboard" => "leaderboard_livecodebench"})
    _, out = run({"command" => "leaderboard", "-b" => "livecodebench"})
    REQUESTS.should eq ["/benchmarks/livecodebench/leaderboard?limit=10"]
    out.should contain "2  Gemini 3 Flash Preview (Reasoning)  Google    90.8   $0.50 / $3.00 per M"
    out.should_not contain "Value"
  end

  it "shows the top of every dimension, media prices included" do
    stub({"/rankings" => "rankings"})
    _, out = run({"command" => "leaderboard"})
    REQUESTS.should eq ["/rankings?limit=3"]
    out.should contain "coding\n#  Model"
    out.should match %r{text-to-image\n.*\n1 .*\$[\d.]+/image}
  end

  it "prints the raw API JSON with --json" do
    stub({"/rankings" => "rankings"})
    _, out = run({"command" => "leaderboard", "--json" => true})
    out.strip.should eq fixture("rankings").strip
  end

  it "recommends for a task and what to minimize" do
    stub({"/recommend" => "recommend"})
    _, out = run({"command" => "recommend", "--task" => "coding", "--minimize" => "hallucinations"})
    REQUESTS.should eq ["/recommend?task=coding&minimize=hallucinations&limit=10"]
    out.should contain "Dimensions (weight): coding (1), safety (2) | minimize: hallucinations | measured: complete"
    out.should contain "1  Meta: Llama 3.3 70B Instruct  Meta      90.2   $0.10 / $0.32 per M  safety 100.0 coding 70.5"
  end

  it "compares models resolved by slug and by provider model ID" do
    stub({"/models/openai-gpt-4o" => "model_gpt4o", "/models?provider_model_id=gpt-4o-mini" => "models", "/models/openai-gpt-4o-mini" => "model_gpt4o"})
    _, out = run({"command" => "compare", "models" => ["openai-gpt-4o", "gpt-4o-mini"]})
    REQUESTS.should eq ["/models/openai-gpt-4o", "/models/gpt-4o-mini", "/models?provider_model_id=gpt-4o-mini", "/models/openai-gpt-4o-mini"]
  end

  it "compares side by side with mean normalized dimension scores" do
    stub({"/models/" => "model_gpt4o"})
    _, out = run({"command" => "compare", "models" => ["openai-gpt-4o", "openai-gpt-4o"]})
    out.should contain "Price     $2.50 / $10.00 per M  $2.50 / $10.00 per M"
    out.should match /^speed\s+71\.9\s+71\.9$/m
  end

  it "lists prices and shows one model's prices" do
    stub({"/pricing" => "pricing"})
    _, out = run({"command" => "pricing", "--limit" => "2"})
    REQUESTS.should eq ["/pricing?page=1&per_page=2"]
    out.should contain "A.X-K2               SK Telecom  $0.00 / $0.00 per M  artificial_analysis"
    stub({"/models/openai-gpt-4o" => "model_gpt4o"})
    _, out = run({"command" => "pricing", "--model" => "openai-gpt-4o"})
    out.should contain "OpenAI: GPT-4o (openai-gpt-4o)"
    out.should contain "output per million tokens        $10.00"
  end

  it "searches the catalog by every word, exact matches first" do
    stub({"/models?page=1" => "models"})
    _, out = run({"command" => "search", "query" => "GPT 4o"})
    out.lines[1].should start_with "openai-gpt-4o-mini  OpenAI: GPT-4o-mini"
    out.lines.size.should eq 2
  end

  it "reports a 429 with its Retry-After" do
    stub({"/rankings" => "rankings"}, 429, HTTP::Headers{"Retry-After" => "42"})
    status, out = run({"command" => "leaderboard"})
    status.should eq ACON::Command::Status::FAILURE
    out.should contain "Retry after 42 seconds."
  end

  it "reports API errors" do
    stub({} of String => String)
    status, out = run({"command" => "pricing", "--model" => "x"})
    status.should eq ACON::Command::Status::FAILURE
    out.should contain "No model matches 'x'"
  end
end
