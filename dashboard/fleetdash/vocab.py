"""Closed vocabularies. A value outside these sets is a bug, not new data."""

# How bad an event is. Retention is set per severity, so every severity here
# must have a row in the config's "retention" table.
SEVERITIES = ("pass", "info", "deny", "redact", "quota", "error")

# What kind of event it is. The Logs page shows one table per category.
CATEGORIES = (
    "tool-call",      # the audit hook saw a tool call it let through
    "denial",         # a rule, the classifier or a hook refused a tool call
    "redaction",      # the redaction hook hid a credential from the model
    "api-error",      # the API answered with an error status
    "rate-limit",     # a 5-hour or weekly limit refused a request
    "slash-command",  # the user ran a /command (name only, never its arguments)
    "skill",          # a reply was attributed to a skill
    "plugin",         # a reply was attributed to a plugin
    "log-integrity",  # a hook log file is not owned by the user it is named for
)

# Who answered a model call, and so who bills it. The Overview has one table
# for each, in this order.
PROVIDERS = ("anthropic", "bedrock")

# The model name Claude Code gives a message it wrote itself, such as the
# notice it shows for an API error. No model was called and no tokens used.
NOT_A_MODEL = "<synthetic>"

# How a run started from the Update page stands. The store holds these.
RUN_STATES = (
    "running",      # started, and no result yet
    "done",         # it ended by itself: it has an exit code
    "timed-out",    # stopped at its time limit: no exit code
    "not-started",  # the command could not be started at all
)
# What a page is told for a row still marked running that no server is
# running: the server stopped while it ran, and its result is not known.
RUN_INTERRUPTED = "interrupted"
