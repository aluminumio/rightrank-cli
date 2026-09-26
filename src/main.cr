require "./rightrank"

# Colorize's default (a TTY, and no NO_COLOR) decides color; --ansi and --no-ansi override it.
RightRank.app.run(output: ACON::Output::ConsoleOutput.new(decorated: Colorize.enabled?))
