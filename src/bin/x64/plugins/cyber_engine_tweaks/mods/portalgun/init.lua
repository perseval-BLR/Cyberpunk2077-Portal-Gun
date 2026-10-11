-- Portal Gun for Cyberpunk 2077 v1.0.0 - fan-made, non-commercial. See README / CREDITS.
-- Portal Gun for Cyberpunk 2077 (Cyber Engine Tweaks part). Development notes: portal-cp/NOTES.md.
--
-- The gun (Items.PortalGun, r6/tweaks/portalgun.yaml) is given a few seconds after a load. In hands: left mouse - blue
-- portal, right mouse - orange (its own shooting, aiming and reloading are switched off). Bindings (CET overlay ->
-- Bindings): portal_blue / portal_orange - shoot with any weapon, portal_clear - remove both, portal_give - the gun.
-- A shot flies from the muzzle to the static surface under the crosshair; the portal opens there: an entity of our
-- own (Codeware StaticEntitySystem) with the animated oval (8 frames swapped by script) and a light. With both
-- portals placed each gets a copy of the game's own portal device whose camera looks out of it and whose screen shows
-- the view out of the other portal (the engine draws it only within ~20 m). Walking into a portal pulls V into it and
-- pushes her out of the other at the speed she came in; NPCs go through too (ragdolled, sucked in, pushed out).
-- Log: log.txt next to this file.

local RANGE = 2000  -- run 14/16 (owner: 'the range as far as it goes'): 80 -> 2000 m; the real limit is the collision
                    -- the game keeps streamed in around V - past it the ray finds nothing ('No surface')
local HALF_W, HALF_H = 0.55, 0.95       -- the portal oval, m
local COOLDOWN = 0.8
local MIN_GAP = 1.4                     -- the two portals' centres at least this far apart
local FX_ENT, PORTAL_MESH = "portal\\fx\\empty.ent", "portal\\fx\\portal_disc.mesh"
local COLORS = {blue = {40, 160, 255}, orange = {255, 140, 20}}

local portals = {blue = nil, orange = nil}
local on_assemble = {}   -- entity key -> function(entity), run once when it is assembled (the see-through tests)
local log_lines, hud = {}, {text = nil, t = 0}
local tp = {cooldown = 0, last_pos = nil, player_key = nil}

local function Log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    print("[portalgun] " .. line)
    log_lines[#log_lines + 1] = os.date("%H:%M:%S ") .. line
    if #log_lines > 400 then table.remove(log_lines, 1) end
    local f = io.open("log.txt", "w")
    if f then f:write(table.concat(log_lines, "\n"), "\n"); f:close() end
end

local function Hud(text, t) hud.text, hud.t = text, t or 2 end

-- vectors -------------------------------------------------------------------------------------------------------
local function V4(x, y, z) return Vector4.new(x, y, z, 1.0) end
local function add(a, b) return V4(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return V4(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return V4(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return V4(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function norm(a) local l = len(a); if l < 1e-6 then return nil end; return mul(a, 1 / l) end
local function fmt(v) return v and string.format("(%.2f %.2f %.2f)", v.x, v.y, v.z) or "nil" end
local function Yaw(v) local e = nil; pcall(function() e = Vector4.ToRotation(v) end); return e and e.yaw or 0 end
local UP   -- V4(0, 0, 1), set in onInit: game types like Vector4 are not there yet when CET loads the file

-- quaternion of the rotation whose columns (local X, Y, Z in world space) are x, y, z
local function QFromBasis(x, y, z)
    local m00, m01, m02 = x.x, y.x, z.x
    local m10, m11, m12 = x.y, y.y, z.y
    local m20, m21, m22 = x.z, y.z, z.z
    local tr = m00 + m11 + m22
    local qw, qx, qy, qz
    if tr > 0 then
        local s = math.sqrt(tr + 1) * 2
        qw = 0.25 * s; qx = (m21 - m12) / s; qy = (m02 - m20) / s; qz = (m10 - m01) / s
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1 + m00 - m11 - m22) * 2
        qw = (m21 - m12) / s; qx = 0.25 * s; qy = (m01 + m10) / s; qz = (m02 + m20) / s
    elseif m11 > m22 then
        local s = math.sqrt(1 + m11 - m00 - m22) * 2
        qw = (m02 - m20) / s; qx = (m01 + m10) / s; qy = 0.25 * s; qz = (m12 + m21) / s
    else
        local s = math.sqrt(1 + m22 - m00 - m11) * 2
        qw = (m10 - m01) / s; qx = (m02 + m20) / s; qy = (m12 + m21) / s; qz = 0.25 * s
    end
    return Quaternion.new(qx, qy, qz, qw)
end

-- the portal's frame: n out of the surface, u "up" on it (world up for walls, the aim for floors/ceilings), r right
local function Frame(n, fwd)
    local u
    if math.abs(n.z) > 0.7 then
        u = norm(sub(fwd, mul(n, dot(fwd, n)))) or norm(sub(V4(1, 0, 0), mul(n, n.x)))
    else
        u = norm(sub(UP, mul(n, n.z)))
    end
    local r = norm(cross(n, u))
    return r, u
end

-- raycast ---------------------------------------------------------------------------------------------------------
local function Ray(from, to)
    local best = nil
    for _, group in ipairs({"Static", "Terrain"}) do
        local ok, hit, res = pcall(function()
            return Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(from, to, group, false, false)
        end)
        if ok and hit and res then
            local p = ToVector4(res.position)
            local d = len(sub(p, from))
            if not best or d < best.d then
                local n = nil
                pcall(function() n = ToVector4(res.normal) end)
                if n and len(n) < 0.5 then n = nil end
                best = {p = p, d = d, n = n and norm(n), group = group}
            end
        end
    end
    return best
end

-- the surface normal: from the trace if it has one, else from the plane through three close hits
local function Surface(from, fwd)
    local h = Ray(from, add(from, mul(fwd, RANGE)))
    if not h then return nil end
    if h.n then
        if dot(h.n, fwd) > 0 then h.n = mul(h.n, -1) end
        h.nsrc = "trace"
        return h
    end
    local side = norm(cross(fwd, UP)) or V4(1, 0, 0)
    local upv = norm(cross(side, fwd))
    local e = 0.01
    local h1 = Ray(from, add(from, mul(norm(add(fwd, mul(side, e))), RANGE)))
    local h2 = Ray(from, add(from, mul(norm(add(fwd, mul(upv, e))), RANGE)))
    if h1 and h2 then
        local n = norm(cross(sub(h1.p, h.p), sub(h2.p, h.p)))
        if n then
            if dot(n, fwd) > 0 then n = mul(n, -1) end
            h.n, h.nsrc = n, "3 rays"
            return h
        end
    end
    h.n, h.nsrc = mul(fwd, -1), "facing (fallback)"
    return h
end

-- portal entities -----------------------------------------------------------------------------------------------
local function Despawn(p)
    if p and p.id then pcall(function() Game.GetStaticEntitySystem():DespawnEntity(p.id) end) end
end

local function Spawn(p)
    local ok, err = pcall(function()
        local spec = StaticEntitySpec.new()
        spec.templatePath = FX_ENT
        spec.position = p.c
        spec.orientation = QFromBasis(p.r, p.n, p.u)
        spec.attached = true
        p.id = Game.GetStaticEntitySystem():SpawnEntity(spec)
        p.idkey = tostring(p.id.hash)
    end)
    Log("%s portal: spawn %s", p.color, ok and ("id " .. tostring(p.idkey)) or ("failed: " .. tostring(err)))
    return ok
end

-- the portal (run 3: animated): FRAMES mesh components of our own mesh at real size (portal_disc.mesh: oval + rim;
-- appearance <colour><i> = frame i of the loop - the swirl running inwards, the rim's flames running around); only one
-- is switched on at a time (IComponent.Toggle), the next one every 1/ANIM_FPS s. Each frame sits FRAME_STEP higher
-- than the one before, so if Toggle did not hide them the top one would just show still, without flicker. A new
-- portal opens from a point: the shown frame's visualScale grows over OPEN_TIME s (Toggle off/on after each change,
-- as entSpawner does).
local FRAMES, ANIM_FPS, OPEN_TIME, FRAME_STEP = 8, 12, 0.25, 0.0004

local function Mesh(app, i)
    local c = entMeshComponent.new()
    c.name = "f" .. i
    c.mesh = ResRef.FromString(PORTAL_MESH)
    c.meshAppearance = app
    c.visualScale = Vector3.new(1, 1, 1)
    c:SetLocalPosition(Vector4.new(0, FRAME_STEP * i, 0, 0))
    return c
end

local function Light(rgb)
    local c = gameLightComponent.new()
    c.name = "portal_light"
    c.color = Color.new({Red = rgb[1], Green = rgb[2], Blue = rgb[3], Alpha = 255})
    c.intensity = 60
    c.turnOnByDefault = true
    c.radius = 4
    c.type = ELightType.LT_Point
    c.EV = 0
    c.useInParticles = true
    c.useInTransparents = true
    c:SetLocalPosition(Vector4.new(0, 0.3, 0, 0))
    return c
end

-- the shot (run 5, owner: 'when a portal is fired - the effect from the gun too'): Portal's shot is a bright ball of
-- the portal's colour with a short trail, flying from the gun to the wall, and the portal opens where it lands. Here: an
-- entity of our own (empty.ent + portal\fx\portal_shot.mesh, appearance = the colour, and a light) spawned at the gun's
-- muzzle, its Y towards the hit, moved every frame with SetWorldTransform (entSpawner moves its objects so) at
-- SHOT_SPEED; on arrival it goes and the portal is placed (the old one of that colour closes then). The new portal's
-- light flashes and dies down to its glow over FLASH_TIME s. The muzzle: the weapon's position + MUZZLE along its axes
-- (the gun model's tip, blend/build_gun_mesh.py: y up to 0.43 m).
local SHOT_MESH = "portal\\fx\\portal_shot.mesh"
local SHOT_SPEED, MUZZLE = 50, {0, 0.42, 0.03}   -- run 6: 90 -> 50 m/s (shots of 3-17 m flew 0.03-0.2 s)
local SHOT_MAX_TIME = 0.8   -- run 14: far shots fly faster - never longer than this
local FLASH_TIME, FLASH, GLOW = 0.6, 450, 60
local shots = {}

local function ShotMesh(color)
    local c = entMeshComponent.new()
    c.name = "shot"
    c.mesh = ResRef.FromString(SHOT_MESH)
    c.meshAppearance = color
    c.visualScale = Vector3.new(1, 1, 1)
    return c
end

local function Assemble(entity)
    local key = nil
    pcall(function() key = tostring(entity:GetEntityID().hash) end)
    for _, p in pairs(portals) do
        if p and p.idkey == key and not p.assembled then
            p.assembled = true
            local ok, err = pcall(function()
                for i = 0, FRAMES - 1 do entity:AddComponent(Mesh(p.color .. i, i)) end
                local l = Light(COLORS[p.color])
                l.intensity = FLASH
                entity:AddComponent(l)
            end)
            Log("%s portal: assembled, components %s", p.color, ok and "added" or ("failed: " .. tostring(err)))
        end
    end
    local fn = key and on_assemble[key]
    if fn then
        on_assemble[key] = nil
        local ok, err = pcall(fn, entity)
        if not ok then Log("assemble hook failed: %s", tostring(err)) end
    end
    for _, s in pairs(shots) do
        if s and s.idkey == key and not s.assembled then
            s.assembled = true
            local ok, err = pcall(function()
                entity:AddComponent(ShotMesh(s.color))
                local l = Light(COLORS[s.color])
                l.name, l.intensity, l.radius = "shot_light", 250, 3
                l:SetLocalPosition(Vector4.new(0, 0, 0, 0))
                entity:AddComponent(l)
            end)
            Log("%s shot: assembled after %.2f s, components %s", s.color, s.t, ok and "added" or ("failed: " .. tostring(err)))
        end
    end
end

local function FrameComp(e, i)
    local c = nil
    pcall(function() c = e:FindComponentByName(CName.new("f" .. i)) end)
    return c
end

-- after a change of visualScale: entSpawner toggles the component and calls RefreshAppearance
local function Refresh(c)
    pcall(function() c:Toggle(false); c:Toggle(true) end)
    pcall(function() c:RefreshAppearance() end)
end

local function AnimTick(dt)
    for _, p in pairs(portals) do
        if p and p.assembled then
            local e = nil
            pcall(function() e = Game.GetStaticEntitySystem():GetEntity(p.id) end)
            if e then
                if not p.anim then
                    local found = 0
                    for i = 0, FRAMES - 1 do
                        local c = FrameComp(e, i)
                        if c then
                            found = found + 1
                            pcall(function() c:Toggle(i == 0) end)
                        end
                    end
                    p.anim = {frame = 0, t = 0, open = 0, flash = 0}
                    Log("%s portal: animation - %d of %d frame components", p.color, found, FRAMES)
                end
                local a = p.anim
                if a.flash < FLASH_TIME then
                    a.flash = math.min(FLASH_TIME, a.flash + dt)
                    local k = a.flash / FLASH_TIME
                    pcall(function()
                        e:FindComponentByName(CName.new("portal_light")):SetIntensity(GLOW + (FLASH - GLOW) * (1 - k) * (1 - k))
                    end)
                end
                if a.open < OPEN_TIME then
                    a.open = math.min(OPEN_TIME, a.open + dt)
                    local k = a.open / OPEN_TIME
                    local s = 0.05 + 0.95 * (1 - (1 - k) * (1 - k))      -- ease out
                    local c = FrameComp(e, 0)
                    if c then
                        pcall(function() c.visualScale = Vector3.new(s, 1, s) end)
                        Refresh(c)
                    end
                else
                    a.t = a.t + dt
                    if a.t >= 1 / ANIM_FPS then
                        a.t = a.t - 1 / ANIM_FPS
                        if a.t > 1 / ANIM_FPS then a.t = 0 end
                        local old, new = FrameComp(e, a.frame), nil
                        a.frame = (a.frame + 1) % FRAMES
                        new = FrameComp(e, a.frame)
                        if new then pcall(function() new:Toggle(true) end) end
                        if old then pcall(function() old:Toggle(false) end) end
                    end
                end
            end
        end
    end
end

local function Muzzle(player, from, fwd)
    local p = nil
    pcall(function()
        local w = Game.GetTransactionSystem():GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight"))
        local o = ToVector4(w:GetWorldPosition())
        local r, f, u = ToVector4(w:GetWorldRight()), ToVector4(w:GetWorldForward()), ToVector4(w:GetWorldUp())
        p = add(add(add(o, mul(r, MUZZLE[1])), mul(f, MUZZLE[2])), mul(u, MUZZLE[3]))
    end)
    if p and len(sub(p, from)) < 2 then return p, "weapon" end
    return add(add(from, mul(fwd, 0.6)), mul(UP, -0.2)), "camera"   -- no weapon object: below the crosshair
end

-- the see-through view (runs 9-11; owner: 'try to finish the camera'; test 4 showed the game's own portal device
-- drawing a live picture when spawned; 'the pictures must be in both screens - each its own, as in Valve's game';
-- 'naturally when there are 2 portals, when 1 - no'): when both portals stand, each gets a copy of that device
-- (portal\view\portal_view.ent, appearance view_<colour>, tools/make_view_files.py) at the same place and turn: its
-- screen is our oval (over the swirl, under the rim) showing view_<colour>.dtex; its camera and virtual camera (named
-- portalgun_cam_<colour>) look out of the wall and write the OTHER colour's texture - looking into one portal V sees
-- what is in front of the other. Both run all the time. With one portal there is no device (the swirl shows). The
-- device's trigger areas and colliders go off when it is assembled (it has no linked portal, and V must pass); its
-- cameras go on then; the screen and its widget are never switched (runs 9-10: switched ones stayed black / unseen).
local VIEW_ENT = "portal\\view\\portal_view.ent"
local VIEW_LIFT = 0.014
local VIEW_OFF = {"teleport", "activate_stream", "other_side", "colider", "Component"}
local VIEW_CAM = {"render_to_texture_component", "virtual_camera_portal"}
-- run 12 (run 11: both portals showed the swirl - the screens never appeared; the game's device seems to hide its
-- screen when attached until a stream is on): exactly test 4's order, which showed the picture - once the device is in
-- the world, its cameras, widget and screen are switched ON (never off)
local VIEW_ON = {"render_to_texture_component", "virtual_camera_portal", "stream_view_ui", "stream_video_screen"}
-- run 15: a tuning window (camera streamingDistance, widget screenAreaMultiplier / spawnDistanceOverride, live and on
-- respawn) changed nothing - the picture still went at under ~20 m: the engine's limit; the window is gone (owner:
-- 'the distance we leave alone - remove it').
-- run 16 (owner: 'sometimes the picture comes only after the portal is made again; sometimes the swirl stays even
-- close by'): the device's own script seems to hide its screen at times after our one switch-on - a watchdog checks
-- the cameras, widget and screen every VIEW_WATCH s and switches back on what is off (logged).
local VIEW_WATCH = 1.0

local function Switch(e, names, on)
    local n = 0
    for _, nm in ipairs(names) do
        local c = nil
        pcall(function() c = e:FindComponentByName(CName.new(nm)) end)
        if c then
            pcall(function() c:Toggle(on) end)
            pcall(function() c.isEnabled = on end)
            n = n + 1
        end
    end
    return n
end

local function ViewSpawn(p)
    local ok, err = pcall(function()
        local spec = StaticEntitySpec.new()
        spec.templatePath = VIEW_ENT
        spec.appearanceName = "view_" .. p.color
        -- run 13 (owner: 'the picture flickers now and then'): the screen sat at 6 mm, the swirl's frames at 4 mm + up
        -- to 2.8 mm (FRAME_STEP) - the top frames came over it 12 times a second. The device goes VIEW_LIFT out, so the
        -- screen is at 2 cm, above every frame (the rim is a ring outside the oval - no overlap)
        spec.position = add(p.c, mul(p.n, VIEW_LIFT))
        spec.orientation = QFromBasis(p.r, p.n, p.u)
        spec.attached = true
        p.view_id = Game.GetStaticEntitySystem():SpawnEntity(spec)
    end)
    Log("%s view: spawn %s", p.color, ok and tostring(p.view_id and p.view_id.hash) or ("failed: " .. tostring(err)))
    if ok and p.view_id then
        on_assemble[tostring(p.view_id.hash)] = function(e)
            local off = Switch(e, VIEW_OFF, false)
            local cam = Switch(e, VIEW_CAM, true)
            Log("%s view: assembled - %d trigger/collider components off, %d camera components on", p.color, off, cam)
        end
        p.view_check = 60
    end
end

local function ViewDespawn(p)
    if p and p.view_id then pcall(function() Game.GetStaticEntitySystem():DespawnEntity(p.view_id) end) end
    if p then p.view_id, p.view_on = nil, nil end
end

local view_dt = 0
local function ViewTick()
    local a, b = portals.blue, portals.orange
    if not (a and b) then
        for _, p in pairs(portals) do if p and p.view_id then ViewDespawn(p); Log("%s view: removed (one portal)", p.color) end end
        return
    end
    for _, p in ipairs({a, b}) do
        if not p.view_id then ViewSpawn(p) end
        if p.view_id and not p.view_on then
            local e = nil
            pcall(function() e = Game.GetStaticEntitySystem():GetEntity(p.view_id) end)
            if e then
                p.view_on = true
                local off = Switch(e, VIEW_OFF, false)
                local on = Switch(e, VIEW_ON, true)
                Log("%s view: in the world - %d trigger/collider off, %d camera/widget/screen components on", p.color, off, on)
                p.view_watch = VIEW_WATCH
            end
        elseif p.view_on then
            p.view_watch = (p.view_watch or VIEW_WATCH) - (view_dt or 0)
            if p.view_watch <= 0 then
                p.view_watch = VIEW_WATCH
                local e = nil
                pcall(function() e = Game.GetStaticEntitySystem():GetEntity(p.view_id) end)
                if e then
                    local fixed = {}
                    for _, nm in ipairs(VIEW_ON) do
                        local c = nil
                        pcall(function() c = e:FindComponentByName(CName.new(nm)) end)
                        local en = true
                        if c then pcall(function() en = c:IsEnabled() end) end
                        if c and not en then
                            pcall(function() c:Toggle(true) end)
                            pcall(function() c.isEnabled = true end)
                            fixed[#fixed + 1] = nm
                        end
                    end
                    for _, nm in ipairs(VIEW_OFF) do
                        local c = nil
                        pcall(function() c = e:FindComponentByName(CName.new(nm)) end)
                        local en = false
                        if c then pcall(function() en = c:IsEnabled() end) end
                        if c and en then pcall(function() c:Toggle(false) end); fixed[#fixed + 1] = nm .. " (off)" end
                    end
                    if #fixed > 0 then Log("%s view: watchdog switched back: %s", p.color, table.concat(fixed, ", ")) end
                end
            end
        end
        if p.view_check then   -- a second after the spawn: the cameras' state into the log
            p.view_check = p.view_check - 1
            if p.view_check <= 0 then
                p.view_check = nil
                local e = nil
                pcall(function() e = Game.GetStaticEntitySystem():GetEntity(p.view_id) end)
                local st = {}
                for _, nm in ipairs(VIEW_CAM) do
                    local c = nil
                    pcall(function() c = e:FindComponentByName(CName.new(nm)) end)
                    local v = "missing"
                    if c then pcall(function() v = tostring(c:IsEnabled()) end) end
                    st[#st + 1] = nm .. " " .. v
                end
                Log("%s view: a second later - %s", p.color, table.concat(st, ", "))
            end
        end
    end
end

local function PlacePortal(p)
    Despawn(portals[p.color])
    ViewDespawn(portals[p.color])
    portals[p.color] = p
    Spawn(p)
end

local function ShotGone(s)
    if s and s.id then pcall(function() Game.GetStaticEntitySystem():DespawnEntity(s.id) end) end
end

local function ShotTick(dt)
    for color, s in pairs(shots) do
        s.t = s.t + dt
        local dist = math.min(s.speed * s.t, s.len)
        local e = nil
        pcall(function() e = Game.GetStaticEntitySystem():GetEntity(s.id) end)
        if e then
            local ok, err = pcall(function()
                local tr = e:GetWorldTransform()
                tr:SetPosition(add(s.from, mul(s.dir, dist)))
                e:SetWorldTransform(tr)
            end)
            if not ok and not s.move_err then s.move_err = true; Log("%s shot: move failed: %s", color, tostring(err)) end
        end
        if dist >= s.len then
            shots[color] = nil
            ShotGone(s)
            PlacePortal(s.p)
            Log("%s shot: landed after %.2f s (%.1f m)%s", color, s.t, s.len, e and "" or " - its entity never showed")
        end
    end
end

local function Fire(color)
    local player = Game.GetPlayer()
    if not player then return end
    local from, fwd = Game.GetTargetingSystem():GetCrosshairData(player)
    if not from or not fwd then Log("%s: no crosshair data", color); return end
    from, fwd = ToVector4(from), norm(ToVector4(fwd))
    local h = Surface(from, fwd)
    if not h then Log("%s: nothing static within %d m", color, RANGE); Hud("No surface"); return end
    local other = portals[color == "blue" and "orange" or "blue"]
    local c = add(h.p, mul(h.n, 0.03))
    if other and len(sub(c, other.c)) < MIN_GAP then
        Log("%s: too close to the other portal (%.2f m)", color, len(sub(c, other.c))); Hud("Too close to the other portal")
        return
    end
    local r, u = Frame(h.n, fwd)
    local p = {color = color, c = c, n = h.n, r = r, u = u, floor = h.n.z > 0.7, ceiling = h.n.z < -0.7}
    Log("%s: hit %s at %.1f m (%s), normal %s from %s, up %s", color, h.group, h.d, fmt(h.p), fmt(h.n), h.nsrc, fmt(u))
    -- the shot from the muzzle to the hit
    local m, msrc = Muzzle(player, from, fwd)
    local d = sub(c, m)
    local L = len(d)
    local dir = norm(d)
    if not dir or L < 0.5 then PlacePortal(p); return end
    ShotGone(shots[color])
    local x = norm(cross(dir, UP)) or V4(1, 0, 0)
    local z = cross(x, dir)
    -- the trail (0.7 m behind the ball) starts at the muzzle, not back in the camera
    local start = math.min(0.7, L * 0.5)
    m, L = add(m, mul(dir, start)), L - start
    local s = {color = color, p = p, from = m, dir = dir, len = L, t = 0, speed = math.max(SHOT_SPEED, L / SHOT_MAX_TIME)}
    local ok, err = pcall(function()
        local spec = StaticEntitySpec.new()
        spec.templatePath = FX_ENT
        spec.position = m
        spec.orientation = QFromBasis(x, dir, z)
        spec.attached = true
        s.id = Game.GetStaticEntitySystem():SpawnEntity(spec)
        s.idkey = tostring(s.id.hash)
    end)
    if not ok then Log("%s shot: spawn failed: %s - portal placed at once", color, tostring(err)); PlacePortal(p); return end
    shots[color] = s
    Log("%s shot: from %s (%s) %.1f m, %.2f s", color, fmt(m), msrc, L, L / s.speed)
end

local function Clear()
    for k, s in pairs(shots) do ShotGone(s); shots[k] = nil end
    for k, p in pairs(portals) do Despawn(p); ViewDespawn(p); portals[k] = nil end
    Log("portals cleared")
end

-- teleport --------------------------------------------------------------------------------------------------------
-- Run 2 (owner: 'a small push through the portal - it is a passage, not a spawn'; 'NPCs need a forced ragdoll like
-- with the gravgun'), run 3 (owner: 'NPCs do not move - only the ragdoll fires'; 'there should be an effect of
-- sucking in and pushing out'; run 2 log: TeleportationFacility.Teleport returned fine but no NPC moved - its hips
-- stayed put 20 frames later, standing or ragdolled):
--   V: near a portal and moving into it (or touching it) she is pulled into its centre for PULL_TIME s (a Teleport
--      per frame, speeding up), then put at the other portal and pushed out along the exit direction for PUSH_TIME s,
--      slowing to 0, at the speed she came in (turned through the portals), at least PUSH_MIN; the push stops short
--      of static geometry.
--   NPCs within NPC_NEAR m of a portal (TSQ_NPC around V every NPC_SCAN s) are checked every frame; the probe is the
--      hips (the feet for a standing NPC on a floor portal). Inside the oval:
--        standing -> AITeleportCommand to the exit (entSpawner moves its NPCs so); 6 frames later, if the hips are
--                    near the exit: a forced ragdoll and a push out;
--        otherwise (the command did not move it, or it is a ragdoll / dead) -> sucked in: a forced ragdoll and a
--                    ragdoll impulse into the portal's centre; SUCK_TIME s later a copy (same record + appearance,
--                    Codeware DynamicEntitySystem as nfsu2-cp spawns people) comes out of the exit - ragdolled (killed
--                    if the original was dead) and pushed out - and the original is removed (Dispose; if that is not
--                    there: its meshes switched off and killed, so nobody walks around invisible). Quest NPCs are
--                    never swapped.
local PULL_TIME, PULL_NEAR = 0.15, 1.0
-- run 4 (owner: "I do not see the push"; run 3 log: 3.9 m/s for 0.35 s = 0.68 m): at least 7 m/s for 0.45 s = 1.6 m
local PUSH_TIME, PUSH_MIN, PUSH_MAX = 0.45, 7.0, 15.0
local NPC_NEAR, NPC_SCAN, NPC_COOLDOWN, NPC_PUSH_MIN, NPC_PUSH_MAX = 3.5, 0.2, 1.5, 7.0, 15.0   -- push min: run 4
local NPC_IMPULSE = 75 * 0.07     -- gravgun-cp's calibration: ragdoll impulse units per 1 m/s (75 kg x 0.07)
local SUCK_TIME, SUCK_SPEED = 0.3, 4.0
local COPY_TAG = "portalgun_copy"
local pull, push = nil, nil       -- V being pulled in / pushed out
local npcs = {scan = 0, near = {}, track = {}, go = {}, busy = {}}

local function Floor(p, from_z)
    local h = Ray(V4(p.x, p.y, from_z), V4(p.x, p.y, from_z - 3))
    return h and h.p.z or nil
end

-- a velocity through the portals: into src -> out of dst (a half turn about the portal's up axis)
local function Through(v, src, dst)
    local vr, vu, vn = dot(v, src.r), dot(v, src.u), dot(v, src.n)
    return add(add(mul(dst.r, -vr), mul(dst.u, vu)), mul(dst.n, -vn))
end

-- the exit direction and speed: the turned velocity, its outward part at least half of it (nothing goes back into
-- the wall), the speed clamped
local function ExitMotion(v, src, dst, smin, smax)
    local out = Through(v, src, dst)
    local s = math.max(smin, math.min(smax, len(out)))
    local vn = dot(out, dst.n)
    local t = sub(out, mul(dst.n, vn))
    local dir = norm(add(mul(dst.n, math.max(vn, 0.5 * len(out), 0.01)), t)) or dst.n
    return dir, s
end

-- where a body (its feet) comes out of dst, and its yaw
local function ExitPos(src, dst, yaw, out)
    local pos, out_yaw
    if dst.floor then
        pos = add(dst.c, mul(dst.n, 0.1))
        out_yaw = yaw
    elseif dst.ceiling then
        pos = add(dst.c, mul(UP, -1.95))
        out_yaw = yaw
    else
        local base = add(dst.c, mul(dst.n, out))
        local fz = Floor(base, dst.c.z + 0.2)
        pos = V4(base.x, base.y, (fz and fz > dst.c.z - 1.2) and (fz + 0.02) or (dst.c.z - 0.95))
        if src.floor or src.ceiling then
            out_yaw = Yaw(dst.n)
        else
            out_yaw = yaw + (Yaw(dst.n) - Yaw(mul(src.n, -1)))
        end
    end
    return pos, out_yaw
end

-- a point in a portal's frame: inside the oval (times grow), how far in front of it, the in-plane position
local function InPortal(src, probe, grow)
    local rel = sub(probe, src.c)
    local d = dot(rel, src.n)
    local x, y = dot(rel, src.r) / HALF_W, dot(rel, src.u) / HALF_H
    local inside = x * x + y * y < (grow or 1) * (src.floor and 1.2 or 1)
    return inside, d, x, y
end

local function TeleportTo(obj, pos, yaw)
    return pcall(function() Game.GetTeleportationFacility():Teleport(obj, pos, EulerAngles.new(0, 0, yaw)) end)
end

-- a yaw-only quaternion built by hand (nfsu2-cp: ToQuat refused a fresh EulerAngles there)
local function QYaw(yaw)
    local y = math.rad(yaw or 0)
    return Quaternion.new(0, 0, math.sin(y / 2), math.cos(y / 2))
end

-- V ---------------------------------------------------------------------------------------------------------------
local function PushTick(player, dt)
    push.t = push.t + dt
    local t = math.min(push.t, PUSH_TIME)
    local dist = math.min(push.s * t - 0.5 * (push.s / PUSH_TIME) * t * t, push.dmax)
    local yaw = push.yaw or player:GetWorldYaw()
    push.yaw = nil   -- the exit yaw once, then V's own (she can look around while pushed)
    TeleportTo(player, add(push.p0, mul(push.dir, dist)), yaw)
    if push.t >= PUSH_TIME then
        Log("push done: %.2f m in %.2f s", dist, push.t)
        push = nil
    end
end

local function PlayerThrough(player, src, dst, v, feet)
    local dir, s = ExitMotion(v, src, dst, PUSH_MIN, PUSH_MAX)
    local pos, yaw = ExitPos(src, dst, player:GetWorldYaw(), 0.35)
    -- room to fly: a ray from the body's middle along the push
    local dmax = s * PUSH_TIME / 2
    local mid = (dst.floor or dst.ceiling) and 0 or 1.0
    local h = Ray(add(pos, mul(UP, mid)), add(add(pos, mul(UP, mid)), mul(dir, dmax + 0.6)))
    if h then dmax = math.max(0, h.d - 0.6) end
    local ok, err = TeleportTo(player, pos, yaw)
    tp.cooldown, tp.last_pos, tp.v = COOLDOWN, nil, nil
    push = ok and {p0 = pos, dir = dir, s = s, dmax = dmax, t = 0, yaw = yaw} or nil
    Log("teleport %s -> %s: from %s (v %s %.1f m/s) to %s yaw %.0f; push %s %.1f m/s, room %.2f m: %s",
        src.color, dst.color, fmt(feet), fmt(v), len(v), fmt(pos), yaw, fmt(dir), s, dmax, ok and "ok" or tostring(err))
end

-- the pull into the source portal's centre: horizontal for a wall (V keeps her height), down into a floor portal
local function PullTarget(src, feet)
    if src.floor then return V4(src.c.x, src.c.y, src.c.z - 0.4) end
    if src.ceiling then return V4(src.c.x, src.c.y, feet.z + 0.4) end
    local c = add(src.c, mul(src.n, -0.15))
    return V4(c.x, c.y, feet.z)
end

local function PullTick(player, dt)
    pull.t = pull.t + dt
    local k = math.min(1, pull.t / PULL_TIME)
    TeleportTo(player, add(pull.p0, mul(sub(pull.target, pull.p0), k * k)), player:GetWorldYaw())
    if k >= 1 then
        local w = pull
        pull = nil
        PlayerThrough(player, w.src, w.dst, w.v, w.p0)
    end
end

-- NPCs ------------------------------------------------------------------------------------------------------------
local function KeyOf(e) local k = nil; pcall(function() k = tostring(e:GetEntityID().hash) end); return k end

-- the Hips slot follows a ragdoll (its entity position stays where it fell - gravgun-cp run 4)
local function Hips(npc)
    local p = nil
    pcall(function()
        local ok, wt = npc:GetSlotComponent():GetSlotTransform(CName.new("Hips"))
        if ok and wt then p = WorldPosition.ToVector4(wt.Position) end
    end)
    return p
end

local function Ragdoll(npc)
    return pcall(function()
        if not ScriptedPuppet.CanRagdoll(npc) then return end
        local ok = pcall(function() npc:QueueEvent(CreateForceRagdollNoPowerPoseEvent("portalgun")) end)
        if not ok then npc:QueueEvent(CreateForceRagdollEvent("portalgun")) end
    end)
end

local function Impulse(npc, at, vel)
    return pcall(function() npc:QueueEvent(CreateRagdollApplyImpulseEvent(at, mul(vel, NPC_IMPULSE), 0.8)) end)
end

local function Flag(e, method)
    local ok, v = pcall(function() return e[method](e) end)
    if ok then return v and true or false end
    return nil
end

-- run 3 crash: the NPC search returned V herself (entity 1) - she was "swapped" (Dispose + a Player_Puppet_Base copy)
-- and the game crashed. Only NPC puppets that are not the player go through; checked again before any swap.
local function IsNPC(e)
    if not e then return false end
    local k = nil
    pcall(function() k = tostring(e:GetEntityID().hash) end)
    if not k or k == tp.player_key then return false end
    local player = false
    pcall(function() player = e:IsPlayer() end)
    if player then return false end
    local npc = false
    pcall(function() npc = e:IsA("NPCPuppet") end)
    return npc
end

local function ScanNPCs(player, ppos)
    local far = 0
    for _, p in pairs(portals) do if p then far = math.max(far, len(sub(p.c, ppos))) end end
    local found, near = 0, {}
    local ok, err = pcall(function()
        local q = Game["TSQ_NPC;"]()
        q.maxDistance = math.min(far + NPC_NEAR + 1, 120)
        q.testedSet = TargetingSet.Complete
        local _, parts = Game.GetTargetingSystem():GetTargetParts(player, q)
        for _, part in ipairs(parts or {}) do
            local e = nil
            pcall(function() e = TS_TargetPartInfo.GetComponent(part):GetEntity() end)
            local k = e and KeyOf(e)
            if k and not near[k] and IsNPC(e) then
                found = found + 1
                local feet = ToVector4(e:GetWorldPosition())
                local hips = Hips(e) or feet
                for _, p in pairs(portals) do
                    if p and (len(sub(hips, p.c)) < NPC_NEAR or len(sub(feet, p.c)) < NPC_NEAR) then near[k] = e end
                end
            end
        end
    end)
    if not ok and not npcs.err_logged then npcs.err_logged = true; Log("npc search failed: %s", tostring(err)) end
    local n = 0
    for _ in pairs(near) do n = n + 1 end
    if n ~= npcs.n_near then Log("npcs near the portals: %d (of %d found within %.0f m)", n, found, far + NPC_NEAR + 1) end
    npcs.near, npcs.n_near = near, n
end

-- the original goes: Dispose if the game has it, else its meshes off and killed (no invisible walker)
local function Remove(e, k)
    if not IsNPC(e) then Log("npc %s: not an NPC - NOT removed", k); return end
    local okd, errd = pcall(function() e:Dispose() end)
    local hidden = 0
    pcall(function()
        for _, c in ipairs(e:GetComponents()) do
            local vis = false
            pcall(function() vis = c:IsA("entIVisualComponent") or c:IsA("entMeshComponent") or c:IsA("entSkinnedMeshComponent") end)
            if vis then pcall(function() c:Toggle(false) end); hidden = hidden + 1 end
        end
    end)
    local killed = false
    if not okd then killed = pcall(function() e:Kill(nil, true, true) end) end
    Log("npc %s: original removed - Dispose %s, %d visual components off%s", k, okd and "ok" or ("failed: " .. tostring(errd)),
        hidden, okd and "" or (killed and ", killed" or ", kill failed"))
end

local function SpawnCopy(w)
    if not IsNPC(w.e) then Log("npc %s: not an NPC - no copy", w.k); return false end
    local rec, app = nil, nil
    pcall(function() rec = w.e:GetRecordID() end)
    pcall(function() app = w.e:GetCurrentAppearanceName() end)
    if not rec then Log("npc %s: no record - no copy", w.k); return false end
    local ok, id = pcall(function()
        local spec = DynamicEntitySpec.new()
        spec.recordID = rec
        if app then spec.appearanceName = app end
        spec.position = w.pos
        spec.orientation = QYaw(w.yaw)
        spec.persistState = false
        spec.persistSpawn = false
        spec.alwaysSpawned = true
        spec.spawnInView = true
        spec.tags = {CName.new(COPY_TAG)}
        return Game.GetDynamicEntitySystem():CreateEntity(spec)
    end)
    Log("npc %s: copy %s (record %s, appearance %s) at %s", w.k, ok and "spawning" or ("failed: " .. tostring(id)),
        tostring(rec and TDBID.ToStringDEBUG(rec)), tostring(app and Game.NameToString(app)), fmt(w.pos))
    if not ok then return false end
    w.copy = id
    return true
end

local function NPCEnter(e, k, tr, src, dst, rag, probe, d, x, y)
    local v = tr.v or V4(0, 0, 0)
    local dir, s = ExitMotion(v, src, dst, NPC_PUSH_MIN, NPC_PUSH_MAX)
    local yaw = 0
    pcall(function() yaw = e:GetWorldYaw() end)
    local pos, out_yaw = ExitPos(src, dst, yaw, 0.5)
    local dead = Flag(e, "IsDead") or false
    local quest = Flag(e, "IsQuest") or false
    local crowd = Flag(e, "IsCrowd")
    local w = {e = e, k = k, src = src, dst = dst, dir = dir, s = s, pos = pos, yaw = out_yaw, f = 0, t = 0,
               dead = dead, quest = quest, origin = probe,
               want = add(pos, mul(UP, (dst.floor or dst.ceiling) and 0.5 or 0.95))}
    if rag or dead then
        w.stage = "suck"
    else
        w.stage = "ai"
    end
    tr.cooldown, tr.last, tr.v = NPC_COOLDOWN + SUCK_TIME + 1, nil, nil
    npcs.busy[k] = true
    npcs.go[#npcs.go + 1] = w
    Log("npc %s %s%s%s%s %s -> %s: probe %s (d %.2f, in-plane %.2f %.2f, v %.1f m/s), exit %s, push %s %.1f m/s -> %s",
        k, rag and "ragdoll" or "standing", dead and " dead" or "", quest and " quest" or "",
        crowd == nil and "" or (crowd and " crowd" or " not-crowd"), src.color, dst.color, fmt(probe), d, x, y, len(v),
        fmt(pos), fmt(dir), s, w.stage)
end

-- one NPC's way through, a step per frame; returns true when done
local function NPCStep(w, dt)
    w.f, w.t = w.f + 1, w.t + dt
    if w.stage == "ai" then
        if w.f == 1 then
            local ok, err = pcall(function()
                local cmd = AITeleportCommand.new()
                cmd.position = w.pos
                cmd.rotation = w.yaw
                cmd.doNavTest = false
                w.e:GetAIControllerComponent():SendCommand(cmd)
            end)
            if not ok then Log("npc %s: AITeleportCommand failed: %s", w.k, tostring(err)) end
        elseif w.f == 7 then
            local h = Hips(w.e)
            local off = h and len(sub(h, w.want)) or 99
            Log("npc %s: AITeleportCommand - hips %s, %.2f m from the exit, %.2f m from where it was", w.k, fmt(h), off,
                h and len(sub(h, w.origin)) or -1)
            if off < 1.5 then
                w.stage, w.f, w.t = "out", 0, 0
            else
                w.stage, w.f, w.t = "suck", 0, 0
            end
        end
    elseif w.stage == "out" then   -- moved for real: ragdoll and push out
        if w.f == 1 then Ragdoll(w.e)
        elseif w.f == 3 then Impulse(w.e, Hips(w.e) or w.want, mul(w.dir, w.s))
        elseif w.f >= 4 then return true end
    elseif w.stage == "suck" then
        if w.f == 1 then
            if not w.dead then Ragdoll(w.e) end
        elseif w.f == 3 then
            local h = Hips(w.e) or w.origin
            local into = norm(sub(add(w.src.c, mul(w.src.n, -0.3)), h)) or mul(w.src.n, -1)
            Impulse(w.e, h, mul(into, SUCK_SPEED))
        end
        if w.t >= SUCK_TIME then
            if w.quest then
                Log("npc %s: a quest NPC - not swapped, left where it is", w.k)
                return true
            end
            if not SpawnCopy(w) then return true end
            Remove(w.e, w.k)
            w.stage, w.f, w.t = "copy", 0, 0
        end
    elseif w.stage == "copy" then
        local c = nil
        pcall(function() c = Game.GetDynamicEntitySystem():GetEntity(w.copy) end)
        if c and not w.ce then
            w.ce, w.cf = c, w.f
            local ck = KeyOf(c)
            if ck then npcs.track[ck] = {cooldown = NPC_COOLDOWN}; w.ck = ck end
            Log("npc %s: copy %s there after %d frames", w.k, tostring(ck), w.f)
        end
        if w.ce then
            local n = w.f - w.cf
            if n == 4 then
                if w.dead then
                    local ok = pcall(function() w.ce:Kill(nil, false, false) end)
                    if not ok then Ragdoll(w.ce) end
                else
                    Ragdoll(w.ce)
                end
            elseif n == 7 then
                Impulse(w.ce, Hips(w.ce) or w.want, mul(w.dir, w.s))
            elseif n == 30 then
                Log("npc %s: copy hips %s (exit %s)", w.k, fmt(Hips(w.ce)), fmt(w.want))
                return true
            end
        elseif w.t > 3 then
            Log("npc %s: the copy did not appear in 3 s", w.k)
            return true
        end
    end
    return false
end

local function NPCTick(player, dt)
    for i = #npcs.go, 1, -1 do
        local ok, done = pcall(NPCStep, npcs.go[i], dt)
        if not ok then Log("npc step failed: %s", tostring(done)); done = true end
        if done then npcs.busy[npcs.go[i].k] = nil; table.remove(npcs.go, i) end
    end
    local a, b = portals.blue, portals.orange
    if not a or not b then npcs.near, npcs.n_near = {}, 0; return end
    npcs.scan = npcs.scan - dt
    if npcs.scan <= 0 then
        npcs.scan = NPC_SCAN
        ScanNPCs(player, ToVector4(player:GetWorldPosition()))
    end
    for k, e in pairs(npcs.near) do
        local tr = npcs.track[k]
        if not tr then tr = {cooldown = 0}; npcs.track[k] = tr end
        if tr.cooldown > 0 then tr.cooldown = tr.cooldown - dt end
        local feet = ToVector4(e:GetWorldPosition())
        local hips = Hips(e)
        local rag = hips and (math.abs(hips.z - feet.z - 0.95) > 0.45
                              or len(V4(hips.x - feet.x, hips.y - feet.y, 0)) > 0.6) or false
        local probe = hips or add(feet, mul(UP, 0.95))
        if tr.last and dt > 0 then
            local nv = mul(sub(probe, tr.last), 1 / dt)
            if len(nv) < 60 then tr.v = tr.v and add(mul(tr.v, 0.5), mul(nv, 0.5)) or nv end
        end
        tr.last = probe
        if tr.cooldown <= 0 and not npcs.busy[k] then
            for _, pair in ipairs({{a, b}, {b, a}}) do
                local src, dst = pair[1], pair[2]
                local pr = (src.floor and not rag) and feet or probe
                local inside, d, x, y = InPortal(src, pr)
                if inside and d > -0.4 and d < (src.floor and 0.35 or 0.6) then
                    NPCEnter(e, k, tr, src, dst, rag, pr, d, x, y)
                    break
                end
            end
        end
    end
end

local function CheckTeleport(dt)
    local player = Game.GetPlayer()
    if not player then return end
    local key = nil
    pcall(function() key = tostring(player:GetEntityID().hash) end)
    if key ~= tp.player_key then
        tp.player_key = key
        portals.blue, portals.orange = nil, nil   -- a new game session: the entities went with the old world
        shots.blue, shots.orange = nil, nil
        pull, push, npcs.near, npcs.track, npcs.go, npcs.busy, npcs.n_near = nil, nil, {}, {}, {}, {}, 0
        return
    end
    NPCTick(player, dt)
    if pull then PullTick(player, dt); return end
    if push then PushTick(player, dt) end
    local feet = ToVector4(player:GetWorldPosition())
    if tp.last_pos and dt > 0 and not push then
        local nv = mul(sub(feet, tp.last_pos), 1 / dt)
        if len(nv) < 60 then tp.v = tp.v and add(mul(tp.v, 0.5), mul(nv, 0.5)) or nv end
    end
    tp.last_pos = (not push) and feet or nil
    if tp.cooldown > 0 then tp.cooldown = tp.cooldown - dt; return end
    if push then return end
    local a, b = portals.blue, portals.orange
    if not a or not b then return end
    local v = tp.v or V4(0, 0, 0)
    for _, pair in ipairs({{a, b}, {b, a}}) do
        local src, dst = pair[1], pair[2]
        local probe = (src.floor or src.ceiling) and feet or add(feet, mul(UP, 1.0))
        local inside, d, x, y = InPortal(src, probe, 1.3)
        local into = -dot(v, src.n)               -- m/s towards the surface
        local near = src.floor and d < 0.35 or (d < 0.5 or (d < PULL_NEAR and into > 0.5))
        if inside and d > -0.3 and near then
            pull = {src = src, dst = dst, p0 = feet, target = PullTarget(src, feet), t = 0, v = v}
            tp.cooldown = COOLDOWN
            Log("pull into %s: from %s (d %.2f, in-plane %.2f %.2f, %.1f m/s towards it)", src.color, fmt(feet), d, x, y, into)
            return
        end
    end
end

-- (the see-through tests of runs 5-8 - the vanilla live-feed screen, live-feed textures on our oval, own render-to-
-- texture cameras, the game's own portal device - are in NOTES.md; their code went with the release clean-up)

-- the gun ---------------------------------------------------------------------------------------------------------
-- Items.PortalGun (TweakXL r6/tweaks/portalgun.yaml): a Militech Saratoga with the portal gun's look (portal.archive).
-- Given a few seconds after a load if V has none (the gravgun-cp way: when the inventory count is stable). In hands:
-- left mouse - blue portal, right mouse - orange; its own shooting, aiming and reloading are switched off.
local GUN = "Items.PortalGun"
local gun = {ready = false, equipped = false, gift_player = nil, gift_t = 0, gift_tick = 0, gift_done = false,
             gift_last = -1, gift_stable = 0}

local function GunName(id)
    local ok, nm = pcall(function() return TDBID.ToStringDEBUG(id) end)
    return ok and nm or nil
end

local function HasGun(player)
    local ok, has = pcall(function()
        local _, list = Game.GetTransactionSystem():GetItemList(player)
        for _, it in ipairs(list or {}) do
            if GunName(it:GetID().id) == GUN then return true end
        end
        return false
    end)
    return ok and has
end

local function GiveGun()
    local player = Game.GetPlayer()
    if not player or not gun.ready then Log("give: no player or no gun record"); return end
    if HasGun(player) then Hud("portal gun: already in the inventory"); Log("give: already there"); return end
    local ok, err = pcall(function() Game.AddToInventory(GUN, 1) end)
    Log("gun given: %s", ok and "yes" or tostring(err))
    Hud(ok and "portal gun added to the inventory" or "could not add the portal gun", 3)
end

local function GunEquipped(player)
    local ok, yes = pcall(function()
        local it = Game.GetTransactionSystem():GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight"))
        return it ~= nil and GunName(it:GetItemID().id) == GUN
    end)
    return ok and yes
end

local function GunTick(dt)
    local player = Game.GetPlayer()
    if not player then return end
    local pid = nil
    pcall(function() pid = tostring(player:GetEntityID().hash) end)
    if pid ~= gun.gift_player then
        gun.gift_player, gun.gift_t, gun.gift_tick, gun.gift_done, gun.gift_last, gun.gift_stable = pid, 0, 0, false, -1, 0
    end
    if not gun.gift_done then
        gun.gift_t, gun.gift_tick = gun.gift_t + dt, gun.gift_tick + dt
        if gun.gift_tick >= 1 then
            gun.gift_tick = 0
            local n = -1
            pcall(function() local _, l = Game.GetTransactionSystem():GetItemList(player); n = #(l or {}) end)
            if n == gun.gift_last and n > 0 then gun.gift_stable = gun.gift_stable + 1 else gun.gift_stable = 0 end
            gun.gift_last = n
            if gun.gift_t > 6 and gun.gift_stable >= 3 then
                gun.gift_done = true
                if gun.ready and not HasGun(player) then GiveGun()
                else Log("gift: %s (%d items)", gun.ready and "V already has the portal gun" or "no gun record", n) end
            end
        end
    end
    local eq = GunEquipped(player)
    if eq ~= gun.equipped then
        gun.equipped = eq
        Log("portal gun %s", eq and "in hands" or "put away")
    end
end

local function OnPlayerAction(action)
    if not gun.equipped then return end
    local name = Game.NameToString(ListenerAction.GetName(action))
    local t = ListenerAction.GetType(action)
    if t ~= gameinputActionType.BUTTON_PRESSED then return end
    if name == "RangedAttack" then Fire("blue")
    elseif name == "CameraAim" then Fire("orange") end
end

local function BlockWhileEquipped(class, method)
    local ok, err = pcall(function()
        Override(class, method, function(this, stateContext, scriptInterface, wrapped)
            if gun.equipped then return false end
            return wrapped(stateContext, scriptInterface)
        end)
    end)
    Log("block %s.%s while the portal gun is in hands: %s", class, method, ok and "ok" or tostring(err))
end

local function GunInit()
    local ok, rec = pcall(function() return TweakDB:GetRecord(GUN) end)
    gun.ready = ok and rec ~= nil
    Log("gun: %s %s", GUN, gun.ready and "found (TweakXL)" or "MISSING - TweakXL and r6/tweaks/portalgun.yaml?")
    for _, c in ipairs({"SemiAutoDecisions", "FullAutoDecisions", "BurstDecisions", "ChargeDecisions",
                        "WindupDecisions", "LockDecisions", "AimingStateDecisions", "ReloadDecisions"}) do
        BlockWhileEquipped(c, "EnterCondition")
    end
    local okh, errh = pcall(function()
        Override("WeaponRosterGameController", "ShouldHideAmmoCount", function(this, ...)
            local args = {...}
            local wrapped = args[#args]
            if gun.equipped then return true end
            return wrapped(unpack(args, 1, #args - 1))
        end)
    end)
    Log("hide the ammo counter while the portal gun is in hands: %s", okh and "ok" or tostring(errh))
    local oki, erri = pcall(function()
        Observe("PlayerPuppet", "OnAction", function(this, action, consumer)
            local okA, errA = pcall(OnPlayerAction, action)
            if not okA then Log("action failed: %s", tostring(errA)) end
        end)
    end)
    Log("input hook: %s", oki and "ok" or tostring(erri))
end

-- CET ---------------------------------------------------------------------------------------------------------
registerForEvent("onInit", function()
    UP = V4(0, 0, 1)
    Log("portalgun loaded (CET %s)", tostring(GetVersion and GetVersion() or "?"))
    local ok, err = pcall(function()
        Observe("EntityBuilder", "OnAssemble", function(_, event)
            if not portals.blue and not portals.orange and not shots.blue and not shots.orange and not next(on_assemble) then return end
            local e = nil
            pcall(function() e = event:GetEntity() end)
            if e then Assemble(e) end
        end)
    end)
    Log("assemble hook: %s", ok and "ok" or tostring(err))
    GunInit()
end)

registerForEvent("onUpdate", function(dt)
    if hud.t > 0 then hud.t = hud.t - dt end
    local oka, erra = pcall(AnimTick, dt)
    local oks, errs = pcall(ShotTick, dt)
    view_dt = dt
    local okv, errv = pcall(ViewTick)
    if not okv and not tp.view_err then tp.view_err = true; Log("view error: %s", tostring(errv)) end
    if not oks and not tp.shot_err then tp.shot_err = true; Log("shot error: %s", tostring(errs)) end
    if not oka and not tp.anim_err then tp.anim_err = true; Log("animation error: %s", tostring(erra)) end
    local okg, errg = pcall(GunTick, dt)
    if not okg and not gun.err_logged then gun.err_logged = true; Log("gun tick error: %s", tostring(errg)) end
    local ok, err = pcall(CheckTeleport, dt)
    if not ok and not tp.err_logged then tp.err_logged = true; Log("teleport check error: %s", tostring(err)) end
end)

registerForEvent("onDraw", function()
    if not hud.text or hud.t <= 0 then return end
    ImGui.SetNextWindowPos(40, 200, ImGuiCond.Always)
    if ImGui.Begin("portalgun_hud", true, ImGuiWindowFlags.NoDecoration + ImGuiWindowFlags.AlwaysAutoResize
                   + ImGuiWindowFlags.NoInputs + ImGuiWindowFlags.NoBackground) then
        ImGui.Text("PORTAL: " .. hud.text)
    end
    ImGui.End()
end)

registerInput("portal_blue", "Shoot the blue portal", function(down) if down then Fire("blue") end end)
registerInput("portal_orange", "Shoot the orange portal", function(down) if down then Fire("orange") end end)
registerHotkey("portal_clear", "Remove both portals", Clear)
registerHotkey("portal_give", "Give the portal gun", GiveGun)
