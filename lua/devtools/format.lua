-- Pure text formatting for Bitty DevTools (bitty-featured.devtools).
--
-- No host access: every function takes plain tables returned by
-- `bitty.debug.*` (or a caught error) and returns bounded strings. Two
-- shapes are produced:
--
-- - the full multi-line text (`inspect`, `trace`, `error`), bounded by the
--   byte limits below and returned as the command result;
-- - a one-line notice (`notice`) derived from it, bounded by
--   NOTIFY_MAX_CHARS characters, which is the only text passed to
--   `bitty.notify.show`.
--
-- A large runtime (up to the host's 1024 inspect items or 10000 trace
-- records) therefore never produces an unbounded body.

local M = {}

-- Maximum number of item / record lines rendered into one body. Sized with
-- MAX_LINE_BYTES so MAX_LINES full lines plus two header lines always fit in
-- MAX_BODY_BYTES; the body cap is a safety net, never the normal cut.
M.MAX_LINES = 15
-- Maximum bytes of one rendered field (ids, titles, topics, payload values).
M.MAX_FIELD_BYTES = 64
-- Maximum bytes of one rendered line.
M.MAX_LINE_BYTES = 112
-- Maximum bytes of a whole notification body.
M.MAX_BODY_BYTES = 2048
-- Maximum payload key/value pairs summarized per trace record.
M.MAX_PAYLOAD_FIELDS = 4
-- Maximum bytes of an error notification body.
M.MAX_ERROR_BYTES = 320
-- Maximum characters (Unicode scalar values, not bytes) of a notification
-- body. Mirrors bitty `bitty-ui/src/window_chrome.rs`
-- `MAX_NOTIFICATION_TEXT_LEN` (256): the host REJECTS a longer body with
-- `ChromeError::TextTooLong` instead of truncating it.
M.NOTIFY_MAX_CHARS = 256
-- Separator replacing line breaks in a one-line notice.
M.NOTICE_SEPARATOR = "; "
-- Marker appended to text cut by a bound.
M.ELLIPSIS = "..."

local CONTINUATION_MIN = 0x80
local CONTINUATION_MAX = 0xBF

local function is_integer(value)
  return type(value) == "number" and value == value and value == math.floor(value)
    and value ~= math.huge and value ~= -math.huge
end

-- Replace control bytes so host text never carries terminal escapes or line
-- breaks from untrusted plugin-supplied strings (titles, ids).
local ASCII_SPACE = 0x20
local ASCII_DELETE = 0x7F

local function sanitize(text)
  local bytes = { string.byte(text, 1, -1) }
  for index, byte in ipairs(bytes) do
    if byte < ASCII_SPACE or byte == ASCII_DELETE then
      bytes[index] = 0x3F -- "?"
    end
  end
  return string.char(table.unpack(bytes))
end

-- Cut `text` to at most `limit` bytes without splitting a UTF-8 sequence;
-- appends ELLIPSIS (counted inside the limit) when anything was removed.
function M.truncate(text, limit)
  if type(text) ~= "string" then
    text = tostring(text)
  end
  if #text <= limit then
    return text
  end
  local keep = limit - #M.ELLIPSIS
  if keep <= 0 then
    return string.sub(M.ELLIPSIS, 1, limit)
  end
  -- Back off while the first dropped byte is a continuation byte, so the cut
  -- lands on a character boundary.
  while keep > 0 do
    local byte = string.byte(text, keep + 1)
    if byte == nil or byte < CONTINUATION_MIN or byte > CONTINUATION_MAX then
      break
    end
    keep = keep - 1
  end
  return string.sub(text, 1, keep) .. M.ELLIPSIS
end

-- Render one scalar field: sanitized and bounded.
function M.field(value)
  if value == nil then
    return "-"
  end
  return sanitize(M.truncate(tostring(value), M.MAX_FIELD_BYTES))
end

-- Join lines into a body bounded by MAX_BODY_BYTES; lines that do not fit
-- are dropped and counted in a trailing marker line.
local function join_bounded(lines)
  local out = {}
  local used = 0
  for index, line in ipairs(lines) do
    local cost = #line + (index > 1 and 1 or 0)
    if used + cost > M.MAX_BODY_BYTES then
      local omitted = #lines - index + 1
      local marker = string.format("(+%d lines omitted)", omitted)
      -- Make room for the marker by dropping already-accepted lines.
      while #out > 0 and used + #marker + 1 > M.MAX_BODY_BYTES do
        used = used - #out[#out] - 1
        out[#out] = nil
        omitted = omitted + 1
        marker = string.format("(+%d lines omitted)", omitted)
      end
      out[#out + 1] = marker
      break
    end
    out[#out + 1] = line
    used = used + cost
  end
  return table.concat(out, "\n")
end

local ROW_RENDERERS = {
  plugins = function(item)
    return string.format(
      "%s %s [%s] gen %s",
      M.field(item.id),
      M.field(item.version),
      M.field(item.state),
      M.field(item.generation)
    )
  end,
  commands = function(item)
    return string.format("%s:%s - %s", M.field(item.plugin), M.field(item.id), M.field(item.title))
  end,
  events = function(item)
    return string.format("%s <- %s", M.field(item.plugin), M.field(item.kind))
  end,
  grants = function(item)
    return M.field(item)
  end,
}

-- Supported inspect targets in display order. `panels` is reserved upstream
-- (E_NOT_IMPLEMENTED) and deliberately absent.
M.INSPECT_TARGETS = { "plugins", "commands", "events", "grants" }

-- Plain-text summary of a `bitty.debug.inspect` result.
-- Returns `title, body`. O(min(n, MAX_LINES)) rendering for n items.
function M.inspect(target, result)
  local render = ROW_RENDERERS[target]
  local title = "DevTools: " .. M.field(target)
  if render == nil or type(result) ~= "table" or type(result.items) ~= "table" then
    return title, "unexpected inspect result shape"
  end
  local items = result.items
  local count = #items
  local header = string.format("%d %s", count, target)
  if result.truncated == true then
    header = header .. " (host list truncated)"
  end
  local lines = { header }
  local shown = math.min(count, M.MAX_LINES)
  for index = 1, shown do
    local item = items[index]
    local line
    if target == "grants" or type(item) == "table" then
      line = render(item)
    else
      line = "?"
    end
    lines[#lines + 1] = M.truncate(line, M.MAX_LINE_BYTES)
  end
  if count > shown then
    lines[#lines + 1] = string.format("(+%d more)", count - shown)
  end
  if count == 0 then
    lines[#lines + 1] = "(none)"
  end
  return title, join_bounded(lines)
end

local function sorted_keys(payload)
  local keys = {}
  for key in pairs(payload) do
    if type(key) == "string" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  return keys
end

-- Compact `k=v` summary of a trace payload: scalar fields only, at most
-- MAX_PAYLOAD_FIELDS pairs. Nested tables render as `{...}`; a non-table
-- payload renders as a type marker such as `<string>`.
function M.payload(payload)
  if type(payload) ~= "table" then
    return "<" .. type(payload) .. ">"
  end
  if payload.truncated == true then
    return string.format("payload truncated (%s bytes)", M.field(payload.bytes))
  end
  local keys = sorted_keys(payload)
  local parts = {}
  for index, key in ipairs(keys) do
    if index > M.MAX_PAYLOAD_FIELDS then
      parts[#parts + 1] = string.format("+%d", #keys - M.MAX_PAYLOAD_FIELDS)
      break
    end
    local value = payload[key]
    local rendered
    if type(value) == "table" then
      rendered = "{...}"
    else
      rendered = M.field(value)
    end
    parts[#parts + 1] = M.field(key) .. "=" .. rendered
  end
  return table.concat(parts, " ")
end

-- Plain-text summary of a drained `bitty.debug.trace_get` result. Shows the
-- most recent MAX_LINES records with timestamps relative to the first
-- drained record, plus per-drain record and dropped counts.
-- Returns `title, body`. O(n) in the drained record count.
function M.trace(result, filter)
  local title = "DevTools: trace"
  if type(result) ~= "table" or type(result.records) ~= "table" then
    return title, "unexpected trace result shape"
  end
  local records = result.records
  local count = #records
  local dropped = is_integer(result.dropped) and result.dropped or 0
  local header = string.format("%d records, %d dropped", count, dropped)
  if type(filter) == "string" then
    header = header .. ", filter " .. M.field(filter)
  end
  local lines = { header }
  if count == 0 then
    lines[#lines + 1] = "(no records; only declared event kinds are traced)"
    return title, join_bounded(lines)
  end
  local base = nil
  local first = records[1]
  if type(first) == "table" and is_integer(first.timestamp) then
    base = first.timestamp
  end
  local start = 1
  if count > M.MAX_LINES then
    start = count - M.MAX_LINES + 1
    lines[#lines + 1] = string.format("(%d earlier records omitted)", start - 1)
  end
  for index = start, count do
    local record = records[index]
    local line
    if type(record) ~= "table" then
      line = "?"
    else
      local offset = "?"
      if base ~= nil and is_integer(record.timestamp) then
        offset = string.format("+%dms", record.timestamp - base)
      end
      line = string.format(
        "#%s %s %s %s",
        M.field(record.sequence),
        offset,
        M.field(record.topic),
        M.payload(record.payload)
      )
    end
    lines[#lines + 1] = M.truncate(line, M.MAX_LINE_BYTES)
  end
  return title, join_bounded(lines)
end

-- Normalize any caught error into `{ code, message }`. Host bridge errors
-- are tables with `code`/`message`; anything else maps to E_UNKNOWN.
function M.error_info(err)
  if type(err) == "table" then
    local code = type(err.code) == "string" and err.code or "E_UNKNOWN"
    local message = type(err.message) == "string" and err.message or ""
    return { code = code, message = message }
  end
  return { code = "E_UNKNOWN", message = tostring(err) }
end

-- Short, human hints for host error codes this plugin expects.
local ERROR_HINTS = {
  E_CAPABILITY_DENIED = "capability not granted",
  E_NOT_IMPLEMENTED = "not available on this host yet",
  E_DEF_LIMIT = "trace limit reached for this plugin",
  E_DEF_INVALID = "invalid request",
  E_TIMEOUT = "host call timed out",
}

-- `<code>: <hint (message)>` for a caught error, unbounded by itself.
local function error_detail(err)
  local info = M.error_info(err)
  local detail = ERROR_HINTS[info.code]
  if info.message ~= "" then
    if detail ~= nil then
      detail = detail .. " (" .. info.message .. ")"
    else
      detail = info.message
    end
  end
  local text = M.field(info.code)
  if detail ~= nil then
    text = text .. ": " .. detail
  end
  return text
end

-- Bounded, sanitized `<code>: <hint>` detail for a caught error.
function M.error_detail(err)
  return sanitize(M.truncate(error_detail(err), M.MAX_ERROR_BYTES))
end

-- Text for a failed action: `<action> failed: <code>: <hint>`.
function M.error(action, err)
  return sanitize(M.truncate(M.field(action) .. " failed: " .. error_detail(err), M.MAX_ERROR_BYTES))
end

-- Cut `text` to at most `limit` characters, appending ELLIPSIS when cut.
-- Valid UTF-8 is cut on a character boundary. Invalid UTF-8 is cut by bytes:
-- the host decodes each invalid byte to at most one replacement character,
-- so `limit` bytes can never exceed `limit` characters.
local function truncate_chars(text, limit)
  local ok, length = pcall(utf8.len, text)
  if not ok or length == nil then
    return M.truncate(text, limit)
  end
  if length <= limit then
    return text
  end
  local cut = utf8.offset(text, limit - #M.ELLIPSIS + 1)
  return string.sub(text, 1, cut - 1) .. M.ELLIPSIS
end

-- One-line notification body derived from full command text: line breaks
-- become NOTICE_SEPARATOR, control bytes are replaced, and the result is at
-- most NOTIFY_MAX_CHARS characters.
function M.notice(text)
  if type(text) ~= "string" then
    text = tostring(text)
  end
  local one_line = (string.gsub(text, "\n", M.NOTICE_SEPARATOR))
  return truncate_chars(sanitize(one_line), M.NOTIFY_MAX_CHARS)
end

return M
