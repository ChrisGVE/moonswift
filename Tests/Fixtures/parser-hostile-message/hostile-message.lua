-- hostile-message.lua — parser-hostile-message fixture
--
-- Raises a runtime error whose message contains the substring "]:1:" which
-- looks like a Lua error location prefix.  The Diagnostic.from(luaError:)
-- parser must not strip or mis-parse the message content; the full error
-- message must survive into the Diagnostic.message field.
error("hostile ]:1: content in message")
