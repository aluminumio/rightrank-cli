require "athena-console"
require "colorize"
require "http/client"
require "json"

module RightRank
  VERSION = "0.1.0"
  API     = ENV["RIGHTRANK_API"]? || "https://rightrank.com/api/v1"

  # An ACON exception, so Athena shows only the message and exits 1.
  class Error < ACON::Exception::Runtime
    getter status : Int32

    def initialize(message : String, @status = 0)
      super(message, 1)
    end
  end

  # Performs a GET on the API. Specs replace it to avoid the network.
  class_property fetch : Proc(String, HTTP::Client::Response) = ->(path : String) do
    HTTP::Client.get(API + path, HTTP::Headers{"User-Agent" => "rightrank-cli/#{VERSION}"})
  end

  def self.request(path : String, **params) : HTTP::Client::Response
    query = URI::Params.build { |q| params.each { |k, v| q.add k.to_s, v.to_s unless v.nil? } }
    res = fetch.call(query.empty? ? path : "#{path}?#{query}")
    return res if res.success?
    raise Error.new("Rate limited by the RightRank API. Retry after #{res.headers["Retry-After"]? || "a few"} seconds.", 429) if res.status_code == 429
    raise Error.new((JSON.parse(res.body)["error"]?.try(&.as_s?) rescue nil) || "HTTP #{res.status_code} for #{path}", res.status_code)
  end

  def self.get(path : String, **params) : String
    request(path, **params).body
  end

  # Models whose slug, name or provider IDs contain every word of *query*, best match first.
  # The API has no search parameter, so this reads the whole catalog, one page per fiber.
  def self.search(query : String) : Array(JSON::Any)
    first = request("/models", page: 1, per_page: 100)
    pages = (first.headers["X-Total-Count"]?.try(&.to_i) || 0).tdiv(100) + 1
    channel = Channel(String).new
    (2..pages).each { |page| spawn { channel.send get("/models", page: page, per_page: 100) } }
    models = ([first.body] + (2..pages).map { channel.receive }).flat_map { |body| JSON.parse(body).as_a }
    q = query.downcase
    words = q.split(/[^a-z0-9.]+/, remove_empty: true)
    models
      .select { |m| words.all? { |w| "#{m["slug"]} #{m["name"]} #{m["provider_model_ids"].as_a.join(' ')}".downcase.includes? w } }
      .sort_by { |m| {m["slug"] == q || m["name"].as_s.downcase == q || m["provider_model_ids"].as_a.includes?(q) ? 0 : 1, m["slug"].as_s.size} }
  end

  # Returns the /models/:slug body for free text: an exact slug, then a provider model ID, then the best search match.
  def self.model(name : String) : String
    begin
      return get("/models/#{URI.encode_path_segment(name)}")
    rescue e : Error
      raise e unless e.status == 404
    end
    slug = JSON.parse(get("/models", provider_model_id: name)).as_a.first?.try(&.["slug"]) ||
           search(name).first?.try(&.["slug"]) || raise Error.new("No model matches '#{name}'. Try: rightrank search #{name}")
    get("/models/#{slug}")
  end
end

module RightRank::Format
  extend self

  def table(headers : Array(String), rows : Array(Array(String)), colors = %i(yellow cyan default green magenta blue)) : String
    widths = headers.map_with_index { |h, i| rows.max_of?(&.[i].size).try { |w| {w, h.size}.max } || h.size }
    lines = [headers.map_with_index { |h, i| h.ljust(widths[i]) }.join("  ").rstrip.colorize.bold.to_s]
    rows.each { |r| lines << r.map_with_index { |c, i| c.ljust(i == r.size - 1 ? 0 : widths[i]).colorize(colors[i]? || :default).to_s }.join("  ") }
    lines.join('\n')
  end

  def num(x : JSON::Any?, digits = 1) : String
    x.try(&.as_f?).try(&.round(digits).to_s) || "-"
  end

  def usd(x : JSON::Any?) : String?
    x.try(&.as_f?).try { |f| "$%.2f" % f }
  end

  def price(p : JSON::Any?) : String
    return "-" unless p
    tokens = "#{usd(p["input_per_million_tokens"]?) || "-"} / #{usd(p["output_per_million_tokens"]?) || "-"} per M" unless p["input_per_million_tokens"]?.try(&.raw).nil? && p["output_per_million_tokens"]?.try(&.raw).nil?
    [tokens, usd(p["per_image"]?).try { |s| "#{s}/image" }, usd(p["per_video_second"]?).try { |s| "#{s}/video s" }].compact.join(", ").presence || p["reason"]?.try(&.as_s?) || "-"
  end

  def ranking(rows : Array(JSON::Any)) : String
    value = rows.any?(&.["value"]?)
    table(["#", "Model", "Provider", "Score", "Price"] + (value ? ["Value"] : [] of String), rows.map_with_index do |r, i|
      [(r["rank"]? || i + 1).to_s, r["model"].as_s, r["provider"].as_s, num(r["score"]? || r["avg_score"]?), price(r["pricing"]?)] + (value ? [num(r["value"]?)] : [] of String)
    end)
  end

  def rankings(json : JSON::Any) : String
    json.as_h?.try(&.join("\n\n") { |dim, rows| "#{dim.colorize.bold.underline}\n#{ranking(rows.as_a)}" }) || ranking(json.as_a)
  end

  def recommend(json : JSON::Any) : String
    head = "Dimensions (weight): #{json["categories"].as_h.join(", ") { |k, v| "#{k} (#{v})" }}" + json["minimize"]?.try(&.as_s?).try { |m| " | minimize: #{m}" }.to_s +
           " | measured: #{json["measurement_status"]}"
    rows = json["recommendations"].as_a.map_with_index do |r, i|
      [(i + 1).to_s, r["model"].as_s, r["provider"]?.to_s, num(r["recommendation_score"]), price(r["pricing"]?), r["category_scores"].as_h.join(" ") { |k, v| "#{k} #{num(v)}" }]
    end
    [head, json["message"]?.try(&.as_s?), rows.empty? ? nil : table(["#", "Model", "Provider", "Score", "Price", "Dimensions"], rows)].compact.join("\n\n")
  end

  def compare(models : Array(JSON::Any)) : String
    dims = models.flat_map { |m| m["dimensions"].as_h.keys }.uniq!
    rows = [
      ["Provider"] + models.map(&.["provider"].to_s),
      ["Released"] + models.map { |m| m["release_date"]?.try(&.as_s?) || "-" },
      ["Context"] + models.map { |m| m["context_window"]?.try(&.as_i64?).try(&.to_s) || "-" },
      ["Price"] + models.map { |m| price(m["pricing"]?) },
      ["Coverage"] + models.map { |m| "#{m["coverage"]["measured"]}/#{m["coverage"]["of"]}" },
    ] + dims.map do |d|
      [d] + models.map { |m| m["dimensions"][d]?.try(&.as_a).try { |a| num(JSON::Any.new(a.sum(&.["normalized_value"].as_f) / a.size)) } || "-" }
    end
    table([""] + models.map(&.["slug"].as_s), rows, %i(yellow)) + "\n\nDimension rows: mean normalized score (0-100, higher is better)."
  end

  def pricing(json : JSON::Any) : String
    return table(["Model", "Provider", "Price", "Source"], json.as_a.map { |r| [r["model"].as_s, r["provider"].to_s, price(r["pricing"]), r["pricing"]["source"].to_s] }, %i(cyan default magenta blue)) if json.as_a?
    p = json["pricing"]
    "#{json["name"].colorize.cyan.bold} (#{json["slug"]})\n" + table(["Price", "USD"], p.as_h.compact_map { |k, v| usd(v).try { |s| [k.gsub('_', ' '), s] } }, %i(default magenta)) +
      "\nSource: #{p["source"]? || p["reason"]?} #{p["captured_at"]?}"
  end

  def search(models : Array(JSON::Any)) : String
    return "No models found." if models.empty?
    table(["Slug", "Name", "Provider", "Coverage", "Price"], models.map { |m| [m["slug"].as_s, m["name"].as_s, m["provider"].to_s, "#{m["coverage"]["measured"]}/#{m["coverage"]["of"]}", price(m["pricing"]?)] }, %i(cyan default default green magenta))
  end
end

module RightRank
  abstract class Command < ACON::Command
    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      body = self.body(input)
      output.puts input.option("json", Bool) ? body : self.render(JSON.parse(body)), output_type: :raw
      Status::SUCCESS
    end

    abstract def body(input : ACON::Input::Interface) : String
    abstract def render(json : JSON::Any) : String
  end

  @[ACONA::AsCommand("leaderboard", description: "Rank models by a benchmark or a dimension (all dimensions without either)")]
  class Leaderboard < Command
    protected def configure : Nil
      self
        .option("benchmark", "b", :required, "Benchmark slug, for example livecodebench")
        .option("dimension", "d", :required, "Dimension, for example coding or long-context")
        .option("limit", "l", :required, "Rows per ranking")
    end

    def body(input) : String
      limit = input.option("limit")
      if b = input.option("benchmark")
        RightRank.get("/benchmarks/#{URI.encode_path_segment(b)}/leaderboard", limit: limit || 10)
      elsif d = input.option("dimension")
        RightRank.get("/rankings/#{URI.encode_path_segment(d.strip.downcase.gsub(/[\s_]+/, "-"))}", limit: limit || 10)
      else
        RightRank.get("/rankings", limit: limit || 3)
      end
    end

    def render(json) : String
      Format.rankings(json)
    end
  end

  @[ACONA::AsCommand("recommend", description: "Recommend models for a free-text task")]
  class Recommend < Command
    protected def configure : Nil
      self
        .option("task", "t", :required, "Task, for example 'coding' or 'image generation'")
        .option("minimize", "m", :required, "What to minimize, for example cost or hallucinations")
        .option("limit", "l", :required, "Number of models", "10")
    end

    def body(input) : String
      RightRank.get("/recommend", task: input.option("task"), minimize: input.option("minimize"), limit: input.option("limit"))
    end

    def render(json) : String
      Format.recommend(json)
    end
  end

  @[ACONA::AsCommand("compare", description: "Compare models side by side")]
  class Compare < Command
    protected def configure : Nil
      self.argument("models", ACON::Input::Argument::Mode.flags(REQUIRED, IS_ARRAY), "Model slugs, provider model IDs or names")
    end

    def body(input) : String
      "[#{input.argument("models", Array(String)).join(',') { |m| RightRank.model(m) }}]"
    end

    def render(json) : String
      Format.compare(json.as_a)
    end
  end

  @[ACONA::AsCommand("pricing", description: "List model prices, or show one model's prices")]
  class Pricing < Command
    protected def configure : Nil
      self
        .option("model", "m", :required, "Model slug, provider model ID or name")
        .option("limit", "l", :required, "Rows per page", "25")
        .option("page", "p", :required, "Page", "1")
    end

    def body(input) : String
      input.option("model").try { |m| RightRank.model(m) } || RightRank.get("/pricing", page: input.option("page"), per_page: input.option("limit"))
    end

    def render(json) : String
      Format.pricing(json)
    end
  end

  @[ACONA::AsCommand("search", description: "Find models by name, slug or provider model ID")]
  class Search < Command
    protected def configure : Nil
      self
        .argument("query", :required, "Words to find, for example 'claude opus'")
        .option("limit", "l", :required, "Number of models", "20")
    end

    def body(input) : String
      RightRank.search(input.argument("query", String)).first(input.option("limit", Int32)).to_json
    end

    def render(json) : String
      Format.search(json.as_a)
    end
  end

  def self.app : ACON::Application
    app = ACON::Application.new("rightrank", VERSION)
    app.definition << ACON::Input::Option.new("json", description: "Print the raw API JSON")
    [Leaderboard.new, Recommend.new, Compare.new, Pricing.new, Search.new].each { |c| app.add c }
    app
  end
end
