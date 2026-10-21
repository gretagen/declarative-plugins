local gen = {}
gen.name = "nixpkgs"

-- Declare system-level nixpkgs packages from definition.lua:
--
--   ["nixpkgs"] = {
--     "nixpkgs#fastfetch",
--     "github:guibou/nixGL",
--   },
--
-- A ref may carry an attribute ("nixpkgs#fastfetch") or be a bare flake ref
-- whose default package is installed ("github:guibou/nixGL").
--
-- Backed by `nix profile add/remove` — the same commands the nixos subspace
-- uses in subspaces_packages, but pinned to the SYSTEM profile
-- (/nix/var/nix/profiles/default) so root's sync makes the tools visible to
-- every user: a bare `nix profile add` would write root's private per-user
-- profile, which no other user's PATH contains. /etc/profile.d/nix-haliade.sh
-- (shipped by the nix package) puts the system profile bin on all login
-- shells. This is the
-- generator shipped by the nix-declarative-helper construct; it only runs when
-- "nixpkgs" is enabled in /etc/nacelle/enabled_modules.lua (see
-- `nix-declarative-helper --help`). The ["nixpkgs"] section's default + schema
-- come from the package's plugin config at
-- /etc/nacelle/plugin-configs/nixpkgs.lua, auto-loaded by config.lua.
--
-- Additions diff against `nix profile list`. nix names an element after the
-- package's `name` attribute, which is usually — but not always — the last
-- component of the installable: nixpkgs#fastfetch appears as "fastfetch", but
-- nixpkgs#kdePackages.dolphin appears as "dolphin". An element counts as the
-- installed form of a ref when its Name matches the ref's last component, or
-- when its Flake attribute equals that component or ends with "." .. it — so
-- kdePackages.* (and similar) refs are not re-planned every sync and are
-- removed by their element name, not their attribute tail. An attribute-less
-- ref (github:guibou/nixGL) is matched by the listing's Original flake URL
-- instead, since nix names such an element after the package's own name, which
-- need not be the ref's tail.
--
-- Removals only ever touch refs THIS generator previously declared, recorded
-- in /var/db/declared-nixpkgs at apply time (mirroring packages-isolated) — a
-- package someone installed themselves with `nix profile add` is never yanked
-- from their declaration, and the record is only written when the command
-- actually ran, so a declined prompt or failed install is retried next sync.

local DECLARED = "/var/db/declared-nixpkgs"

-- The shared system profile. Bare `nix profile` commands would operate on
-- root's private per-user profile instead, which no other user's PATH
-- contains — /etc/profile.d/nix-haliade.sh (nix package) exposes THIS one.
local SYSTEM_PROFILE = "/nix/var/nix/profiles/default"

-- Refs are interpolated into shell commands, so accept only word-ish
-- characters plus the punctuation flake references legitimately use
-- (nixpkgs#fastfetch, github:owner/repo#pkg, path:/srv/flake#pkg,
-- github:guibou/nixGL). No spaces, quotes, $, backticks, ;|&<> — safe to
-- embed unquoted. The '#' attribute part is optional: a bare flake ref
-- installs the flake's default package.
local function valid_ref(r)
  if type(r) ~= "string" or r == "" then return false end
  if not r:match("^[%w%./%:%@%+%#_%-]+$") then return false end
  local hash = r:find("#", 1, true)
  if hash and (hash == 1 or hash == #r or r:find("#", hash + 1, true)) then
    return false
  end
  return true
end

-- The profile element name hint for a ref: the attribute after '#' when
-- present, otherwise the last path/segment component (github:guibou/nixGL →
-- nixGL). For attribute-less flake refs the real element name is the package's
-- own name, so resolve() also matches the listing's Original flake URL.
local function ref_name(r)
  local attr = r:match("#([^#]+)$")
  if attr then return attr end
  return r:match("([^/:]+)$") or r
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
  local desired_list = cfg["nixpkgs"] or {}

  if #desired_list == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- nix is optional (see `nix-declarative-helper --verifynix`): plan nothing
  -- and say why rather than failing the whole sync.
  if sync.shell_output("command -v nix") == "" then
    if #desired_list > 0 then
      io.stderr:write("[warn] nixpkgs: nix is not installed — install it via zeta -Provide nix\n")
    end
    return {}
  end

  -- Validate and de-duplicate the desired refs, keeping declaration order.
  local desired, desired_set, seen = {}, {}, {}
  for _, ref in ipairs(desired_list) do
    if not valid_ref(ref) then
      io.stderr:write("[warn] nixpkgs: skipping invalid reference '"
        .. tostring(ref) .. "' (expected e.g. \"nixpkgs#fastfetch\")\n")
    elseif not seen[ref] then
      seen[ref] = true
      desired[#desired + 1] = ref
      desired_set[ref] = true
    end
  end

  if #desired == 0 and next(read_declared(sync)) == nil then
    return {}
  end

  -- Installed profile elements from `nix profile list`. Tolerates both the
  -- Name: block format (nix 2.19+) and older one-line listings. Each block
  -- element is recorded as { name = <Name: field>, attr = <Flake attribute:
  -- field>, origin = <Original flake URL: field> } — nix names an element after
  -- the package's `name`, which is not always the tail of the ref that
  -- installed it (nixpkgs#kdePackages.dolphin appears as Name: dolphin), so the
  -- attribute is kept for resolution too. The original URL lets an
  -- attribute-less ref resolve even when its element name differs.
  local elements = {}  -- element name -> { name = ..., attr = ..., origin = ... }
  local listing = sync.shell_output("nix profile list --profile " .. SYSTEM_PROFILE)
  local current
  for line in (listing .. "\n"):gmatch("([^\n]+)") do
    local nm = line:match("^Name:%s*(%S+)")
    if nm then
      current = { name = nm }
      elements[nm] = current
    end
    local attr = line:match("^Flake attribute:%s*(%S+)")
    if attr and current then
      current.attr = attr
    end
    local origin = line:match("^Original flake URL:%s*(%S+)")
    if origin and current then
      current.origin = origin
    end
  end
  -- Older one-line listings carry the installable itself as the profile name;
  -- index those too (bare ref and its tail) without clobbering block records.
  for line in (listing .. "\n"):gmatch("([^\n]+)") do
    local tok = line:match("^(%S+#%S+)%s")
    if tok and not elements[tok] and not elements[ref_name(tok)] then
      local el = { name = ref_name(tok) }
      elements[tok] = el
      elements[ref_name(tok)] = el
    end
  end

  -- Resolve a declared ref to an installed element, if any.
  --  * attribute-less flake refs (no '#'): match the listing's Original flake
  --    URL, because nix names such an element after the package's own name and
  --    the ref's tail (e.g. the repo name) may not equal it. Fall back to name.
  --  * attributed refs: by element name, or by flake attribute equal to (or
  --    ending in "." ..) the ref's tail. Without the attribute match, a
  --    kdePackages.*-style ref whose element name differs from its attribute
  --    tail would be re-planned as an add on every sync (nix would just answer
  --    "'dolphin' is already added").
  local function resolve(ref)
    local tail = ref_name(ref)
    if not ref:find("#", 1, true) then
      for _, e in pairs(elements) do
        if e.origin and e.origin:gsub("/+$", "") == ref:gsub("/+$", "") then
          return e
        end
      end
    end
    local el = elements[tail]
    if el then return el end
    for _, e in pairs(elements) do
      if e.attr == tail or (e.attr and e.attr:sub(-(#tail + 1)) == "." .. tail) then
        return e
      end
    end
    return nil
  end

  -- Install what is declared but not present.
  for _, ref in ipairs(desired) do
    if not resolve(ref) then
      table.insert(changes, sync.change("+", "nixpkgs", ref, nil,
        function(_, s)
          local ok = s.shell("nix profile add --profile " .. SYSTEM_PROFILE .. " " .. ref)
          if not ok then
            io.stderr:write("[warn] '" .. ref .. "' nix profile add failed "
              .. "(flake unavailable, network error, or already present)\n")
            return false
          end
          return declare(s, ref)
        end))
    end
  end

  -- Remove what we previously declared and is no longer desired (never touch
  -- entries this generator does not own). The target is the profile ELEMENT
  -- name (the Name: field): nix profile remove expects the element name,
  -- which is not always the ref's tail. Elements already gone from the
  -- profile at plan time are skipped — un-recorded, not re-removed.
  local undeclared = {}
  for ref in pairs(read_declared(sync)) do
    if not desired_set[ref] then undeclared[#undeclared + 1] = ref end
  end
  table.sort(undeclared)

  for _, ref in ipairs(undeclared) do
    local el = resolve(ref)
    table.insert(changes, sync.change("-", "nixpkgs", ref, nil,
        function(_, s)
        if el then
          local ok = s.shell("nix profile remove --profile " .. SYSTEM_PROFILE .. " " .. el.name)
          if not ok then
            io.stderr:write("[warn] '" .. ref .. "' — nix profile remove failed\n")
            return false
          end
        end
        return undeclare(s, ref)
      end))
  end

  return changes
end

return gen
