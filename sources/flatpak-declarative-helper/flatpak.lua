local gen = {}
gen.name = "flatpak"

-- Declare system-level flatpak applications from definition.lua:
--
--   ["flatpak"] = {
--     "flathub:org.mozilla.firefox",
--     "org.videolan.VLC",
--   },
--
-- Backed by `flatpak install/uninstall --system`: installs are system-wide so
-- root's sync makes the apps visible to every user, not just root's private
-- user installation. This is the generator shipped by the
-- flatpak-declarative-helper construct; it only runs when "flatpak" is enabled
-- in /etc/nacelle/enabled_modules.lua (see `flatpak-declarative-helper --help`).
-- The ["flatpak"] section's default + schema come from the package's plugin
-- config at /etc/nacelle/plugin-configs/flatpak.lua, auto-loaded by config.lua.
--
-- A reference is either "remote:appid" (e.g. flathub:org.gnome.Calculator) or
-- a bare "appid", which is looked up on flathub. When a referenced remote is
-- missing it is added automatically IF it is flathub (via `flatpak remote-add
-- --if-not-exists flathub ...`); any other missing remote is reported and its
-- apps skipped rather than silently failing. References are de-duplicated by
-- both their spelling and their app id, so writing the same app twice only
-- plans one install.
--
-- Removals only ever touch refs THIS generator previously declared, recorded
-- in /var/db/declared-flatpak at apply time (mirroring nixpkgs) — an app
-- someone installed themselves with `flatpak install` is never yanked from
-- their declaration, and the record is only written when the install command
-- actually ran, so a declined prompt or failed install is retried next sync.
-- An app already gone from the system is skipped (the record is dropped
-- without running uninstall).

local DECLARED = "/var/db/declared-flatpak"
local DEFAULT_REMOTE = "flathub"
local FLATHUB_REPO = "https://dl.flathub.org/repo/flathub.flatpakrepo"

-- A flatpak application ID is reverse-DNSish (org.mozilla.firefox). Refs are
-- interpolated into shell commands, so accept only word-ish characters plus
-- the dot/hyphen/underscore app IDs use — no spaces, quotes, $, ;|&<>. The dot
-- requirement keeps a stray word from being treated as an app id.
local function valid_appid(a)
  return type(a) == "string"
    and a:match("^[%w_%-%.]+$") ~= nil
    and a:find("%.") ~= nil
end

local function valid_remote(r)
  return type(r) == "string" and r:match("^[%w_%-%.]+$") ~= nil
end

-- Split a declared reference into remote + appid. A bare appid defaults to the
-- flathub remote. Returns nil for anything malformed.
local function parse_ref(ref)
  if type(ref) ~= "string" then return nil end
  local remote, appid = ref:match("^([%w_%-%.]+):([%w_%-%.]+)$")
  if not remote then
    remote, appid = DEFAULT_REMOTE, ref
  end
  if not valid_remote(remote) or not valid_appid(appid) then return nil end
  return remote, appid
end

local function read_declared(sync)
  local set = {}
  local content = sync.read_file(DECLARED) or ""
  for line in (content .. "\n"):gmatch("([^\n]+)") do
    local ref = line:match("^%s*(.-)%s*$")
    if ref and ref ~= "" then set[ref] = true end
  end
  return set
end

-- Record a ref as ours / drop it again. Runs at apply time only.
local function declare(sync, ref)
  sync.shell("mkdir -p /var/db")
  return sync.shell("grep -qxF '" .. ref .. "' " .. DECLARED
    .. " 2>/dev/null || echo '" .. ref .. "' >> " .. DECLARED)
end

local function undeclare(sync, ref)
  return sync.shell("grep -vxF '" .. ref .. "' " .. DECLARED .. " > " .. DECLARED
    .. ".tmp 2>/dev/null; mv -f " .. DECLARED .. ".tmp " .. DECLARED)
end

function gen.plan(cfg, sync)
  local changes = {}
  local desired_list = cfg["flatpak"] or {}

  if #desired_list == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- flatpak is optional (see `flatpak-declarative-helper --verifyflatpak`):
  -- plan nothing and say why rather than failing the whole sync.
  if sync.shell_output("command -v flatpak") == "" then
    if #desired_list > 0 then
      io.stderr:write("[warn] flatpak: flatpak is not installed — install it via zeta -Provide flatpak\n")
    end
    return {}
  end

  -- Validate and de-duplicate the desired refs, keeping declaration order. A
  -- ref is dropped if its spelling OR its app id was already seen, so a bare
  -- "app" and "flathub:app" never plan two installs of the same app.
  local desired, desired_refs, desired_appids = {}, {}, {}
  local seen_ref, seen_appid = {}, {}
  for _, ref in ipairs(desired_list) do
    local remote, appid = parse_ref(ref)
    if not remote then
      io.stderr:write("[warn] flatpak: skipping invalid reference '"
        .. tostring(ref) .. "' (expected e.g. \"flathub:org.mozilla.firefox\" or \"org.mozilla.firefox\")\n")
    elseif not seen_ref[ref] and not seen_appid[appid] then
      seen_ref[ref] = true
      seen_appid[appid] = true
      desired[#desired + 1] = { ref = ref, remote = remote, appid = appid }
      desired_refs[ref] = true
      desired_appids[appid] = true
    end
  end

  if #desired == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- Configured system remotes (one name per line).
  local remotes = {}
  local rl = sync.shell_output("flatpak remotes --system --columns=name")
  for line in (rl .. "\n"):gmatch("([^\n]+)") do
    local nm = line:match("^%s*(%S+)")
    if nm then remotes[nm] = true end
  end

  -- Installed system applications, by app id (one id per line).
  local installed = {}
  local il = sync.shell_output("flatpak list --system --app --columns=application")
  for line in (il .. "\n"):gmatch("([^\n]+)") do
    local a = line:match("^%s*(%S+)")
    if a then installed[a] = true end
  end

  -- Remotes: add flathub if a ref asks for it and it is missing; treat it as
  -- present afterwards so its apps plan normally. Missing non-flathub remotes
  -- are left absent, so pass 2 reports and skips them.
  local add_flathub = false
  for _, d in ipairs(desired) do
    if not remotes[d.remote] and d.remote == DEFAULT_REMOTE then
      add_flathub = true
      remotes[d.remote] = true
    end
  end
  if add_flathub then
    table.insert(changes, sync.change("+", "flatpak", DEFAULT_REMOTE, "remote",
      function(_, s)
        local ok = s.shell("flatpak remote-add --if-not-exists --system "
          .. DEFAULT_REMOTE .. " " .. FLATHUB_REPO)
        if not ok then
          io.stderr:write("[warn] flatpak: could not add the flathub remote\n")
          return false
        end
        return true
      end))
  end

  -- Install what is declared but not present.
  for _, d in ipairs(desired) do
    if not remotes[d.remote] then
      io.stderr:write("[warn] flatpak: remote '" .. d.remote
        .. "' is not configured; skipping " .. d.appid .. "\n")
    elseif not installed[d.appid] then
      table.insert(changes, sync.change("+", "flatpak", d.ref, nil,
        function(_, s)
          local ok = s.shell("flatpak install --system --noninteractive "
            .. d.remote .. " " .. d.appid)
          if not ok then
            io.stderr:write("[warn] '" .. d.ref .. "' flatpak install failed "
              .. "(remote unreachable, app missing, or already installed)\n")
            return false
          end
          return declare(s, d.ref)
        end))
    end
  end

  -- Remove what we previously declared and is no longer desired (never touch
  -- entries this generator does not own). Matching by app id too means a ref
  -- merely re-spelled (bare <-> flathub:app) is not treated as a removal. An
  -- app already gone from the system is skipped — the record is dropped
  -- without running uninstall.
  local undeclared = {}
  for ref in pairs(read_declared(sync)) do
    local _, appid = parse_ref(ref)
    if not desired_refs[ref] and not (appid and desired_appids[appid]) then
      undeclared[#undeclared + 1] = ref
    end
  end
  table.sort(undeclared)

  for _, ref in ipairs(undeclared) do
    local _, appid = parse_ref(ref)
    table.insert(changes, sync.change("-", "flatpak", ref, nil,
      function(_, s)
        if appid and installed[appid] then
          local ok = s.shell("flatpak uninstall --system --noninteractive " .. appid)
          if not ok then
            io.stderr:write("[warn] '" .. ref .. "' — flatpak uninstall failed\n")
            return false
          end
        end
        return undeclare(s, ref)
      end))
  end

  return changes
end

return gen
