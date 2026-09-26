# rightrank

AI model rankings, recommendations and pricing from your terminal, from the [RightRank API](https://rightrank.com/api/v1) ([OpenAPI spec](https://rightrank.com/api/v1/openapi.json), [llms.txt](https://rightrank.com/llms.txt)).

## Install

```sh
brew install aluminumio/tap/rightrank-cli
```

From source (Crystal 1.13 or later):

```sh
git clone https://github.com/aluminumio/rightrank-cli && cd rightrank-cli
shards build --release && cp bin/rightrank /usr/local/bin/
```

## Usage

```sh
rightrank leaderboard                          # top 3 of every dimension
rightrank leaderboard --dimension long-context # one dimension, with cost and value
rightrank leaderboard --benchmark livecodebench --limit 5
rightrank recommend --task coding --minimize hallucinations
rightrank recommend -t "image generation" -m cost
rightrank compare gpt-4o anthropic-claude-opus-4-5 "gemini 2.5 pro"
rightrank pricing                              # all prices, 25 per page (--page, --limit)
rightrank pricing --model gpt-4o
rightrank search claude opus
```

`compare` and `pricing --model` take a RightRank slug (`openai-gpt-4o`), a provider model ID (`gpt-4o`) or a name (`gemini 2.5 pro`). They find the model with the API's `q` search and prefer an exact slug, name or ID match.

Add `--json` to any command to print the raw API JSON. Colors are off when the output is not a terminal or `NO_COLOR` is set; `--ansi` and `--no-ansi` override this. `RIGHTRANK_API` overrides the API base URL.

```
$ rightrank leaderboard -d coding -l 3
#  Model                                                               Provider   Score  Price                 Value
1  Gemini 3 Pro Preview (high)                                         Google     100.0  $2.00 / $12.00 per M  7.1
2  claude-opus-4-5-20251101-thinking-32k                               Anthropic  100.0  $5.00 / $25.00 per M  3.3
3  Claude Opus 5.5 (Adaptive Reasoning, Max Effort, Default Fallback)  Anthropic  100.0  $4.00 / $20.00 per M  4.2
```

## Development

```sh
shards install
crystal spec
crystal tool format --check
```
