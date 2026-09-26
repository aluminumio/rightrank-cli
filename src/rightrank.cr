require "athena-console"
require "colorize"
require "http/client"
require "json"

module RightRank
  VERSION = "0.1.0"
  API     = ENV["RIGHTRANK_API"]? || "https://rightrank.com/api/v1"

  # An ACON exception, so Athena shows only the message; raise it with exit code 1.
  alias Error = ACON::Exception::Runtime

  # Performs a GET on the API. Specs replace it to avoid the network.
  class_property fetch : Proc(String, HTTP::Client::Response) = ->(path : String) do
    HTTP::Client.get(API + path, HTTP::Headers{"User-Agent" => "rightrank-cli/#{VERSION}"})
  end

  def self.get(path : String, **params) : String
    query = URI::Params.build { |q| params.each { |k, v| q.add k.to_s, v.to_s unless v.nil? } }
    res = fetch.call(query.empty? ? path : "#{path}?#{query}")
    return res.body if res.success?
    raise Error.new("Rate limited by the RightRank API. Retry after #{res.headers["Retry-After"]? || "a few"} seconds.", 1) if res.status_code == 429
    raise Error.new((JSON.parse(res.body)["error"]?.try(&.as_s?) rescue nil) || "HTTP #{res.status_code} for #{path}", 1)
  end

  # Returns the /models/:slug body for free text: the `q` match whose slug, name or provider model ID equals it, else the shortest slug.
  def self.model(name : String) : String
    models = JSON.parse(get("/models", q: name, per_page: 100)).as_a
    model = models.find { |m| ([m["slug"], m["name"]] + m["provider_model_ids"].as_a).any?(&.as_s.compare(name, true).zero?) } || models.min_by?(&.["slug"].as_s.size)
    raise Error.new("No model matches '#{name}'.", 1) unless model
    get("/models/#{model["slug"]}")
  end
end

module RightRank::Format
  extend self

  def table(headers : Array(String), rows : Array(Array(String)), colors = %i(yellow cyan default green magenta blue)) : String
    widths = headers.map_with_index { |h, i| ([h] + rows.map(&.[i])).max_of(&.size) }
    lines = [headers.map_with_index { |h, i| h.ljust(widths[i]) }.join("  ").rstrip.colorize.bold.to_s]
    rows.each { |r| lines << r.map_with_index { |c, i| c.ljust(i == r.size - 1 ? 0 : widths[i]).colorize(colors[i]? || :default).to_s }.join("  ") }
    lines.join('\n')
  end

  def num(x : JSON::Any?) : String
    x.try(&.as_f?).try(&.round(1).to_s) || "-"
  end

  def usd(x : JSON::Any?) : String?
    x.try(&.as_f?).try { |f| "$" + (f.zero? || f >= 0.01 ? "%.2f" : "%.2g") % f }
  end

  def price(p : JSON::Any?) : String
    return "-" unless p
    input, output = usd(p["input_per_million_tokens"]?), usd(p["output_per_million_tokens"]?)
    tokens = "#{input || "-"} / #{output || "-"} per M" if input || output
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

  def compare(json : JSON::Any) : String
    models = json.as_a
    dims = models.flat_map { |m| m["dimensions"].as_h.keys }.uniq!
    rows = [
      ["Provider"] + models.map(&.["provider"].to_s),
      ["Released"] + models.map { |m| m["release_date"]?.try(&.as_s?) || "-" },
      ["Context"] + models.map { |m| m["context_window"]?.try(&.as_i64?).try(&.to_s) || "-" },
      ["Price"] + models.map { |m| price(m["pricing"]?) },
      ["Coverage"] + models.map { |m| "#{m["coverage"]["measured"]}/#{m["coverage"]["of"]}" },
    ] + dims.map do |d|
      [d] + models.map { |m| m["dimensions"][d]?.try(&.as_a).try { |a| (a.sum(&.["normalized_value"].as_f) / a.size).round(1).to_s } || "-" }
    end
    table([""] + models.map(&.["slug"].as_s), rows, %i(yellow)) + "\n\nDimension rows: mean normalized score (0-100, higher is better)."
  end

  def pricing(json : JSON::Any) : String
    return table(["Model", "Provider", "Price", "Source"], json.as_a.map { |r| [r["model"].as_s, r["provider"].to_s, price(r["pricing"]), r["pricing"]["source"].to_s] }, %i(cyan default magenta blue)) if json.as_a?
    p = json["pricing"]
    "#{json["name"].colorize.cyan.bold} (#{json["slug"]})\n" + table(["Price", "USD"], p.as_h.compact_map { |k, v| usd(v).try { |s| [k.gsub('_', ' '), s] } }, %i(default magenta)) +
      "\nSource: #{p["source"].as_s? || p["reason"]?} #{p["captured_at"]}"
  end

  def search(json : JSON::Any) : String
    return "No models found." if (models = json.as_a).empty?
    table(["Slug", "Name", "Provider", "Coverage", "Price"], models.map { |m| [m["slug"].as_s, m["name"].as_s, m["provider"].to_s, "#{m["coverage"]["measured"]}/#{m["coverage"]["of"]}", price(m["pricing"]?)] }, %i(cyan default default green magenta))
  end
end

module RightRank
  # Registers a command that prints the API body with --json, else the rendered body.
  def self.command(app, name, description, render : JSON::Any -> String, &body : ACON::Input::Interface -> String) : ACON::Command
    app.register(name) do |input, output|
      Colorize.enabled = output.decorated?
      json = body.call(input)
      output.puts input.option("json", Bool) ? json : render.call(JSON.parse(json)), output_type: :raw
      ACON::Command::Status::SUCCESS
    end.description(description)
  end

  def self.app : ACON::Application
    app = ACON::Application.new("rightrank", VERSION)
    app.definition << ACON::Input::Option.new("json", description: "Print the raw API JSON")

    command(app, "leaderboard", "Rank models by a benchmark or a dimension (all dimensions without either)", ->Format.rankings(JSON::Any)) do |input|
      limit = input.option("limit")
      if b = input.option("benchmark")
        get("/benchmarks/#{URI.encode_path_segment(b)}/leaderboard", limit: limit || 10)
      elsif d = input.option("dimension")
        get("/rankings/#{URI.encode_path_segment(d.strip.downcase.gsub(/[\s_]+/, "-"))}", limit: limit || 10)
      else
        get("/rankings", limit: limit || 3)
      end
    end
      .option("benchmark", "b", :required, "Benchmark slug, for example livecodebench")
      .option("dimension", "d", :required, "Dimension, for example coding or long-context")
      .option("limit", "l", :required, "Rows per ranking")

    command(app, "recommend", "Recommend models for a free-text task", ->Format.recommend(JSON::Any)) do |input|
      get("/recommend", task: input.option("task"), minimize: input.option("minimize"), limit: input.option("limit"))
    end
      .option("task", "t", :required, "Task, for example 'coding' or 'image generation'")
      .option("minimize", "m", :required, "What to minimize, for example cost or hallucinations")
      .option("limit", "l", :required, "Number of models", "10")

    command(app, "compare", "Compare models side by side", ->Format.compare(JSON::Any)) do |input|
      "[#{input.argument("models", Array(String)).join(',') { |m| model(m) }}]"
    end
      .argument("models", ACON::Input::Argument::Mode.flags(REQUIRED, IS_ARRAY), "Model slugs, provider model IDs or names")

    command(app, "pricing", "List model prices, or show one model's prices", ->Format.pricing(JSON::Any)) do |input|
      input.option("model").try { |m| model(m) } || get("/pricing", page: input.option("page"), per_page: input.option("limit"))
    end
      .option("model", "m", :required, "Model slug, provider model ID or name")
      .option("limit", "l", :required, "Rows per page", "25")
      .option("page", "p", :required, "Page", "1")

    command(app, "search", "Find models by name, slug or provider model ID", ->Format.search(JSON::Any)) do |input|
      get("/models", q: input.argument("query", Array(String)).join(' '), per_page: input.option("limit"))
    end
      .argument("query", ACON::Input::Argument::Mode.flags(REQUIRED, IS_ARRAY), "Text to find in model names, slugs and provider model IDs")
      .option("limit", "l", :required, "Number of models", "20")

    app
  end
end
