local PRESETS = {
    custom = {
        step_size_px = 90.0,
        pulse_scale = 1.0,
        animation_time_ms = 360.0,
        acceleration_delta_ms = 70.0,
        acceleration_scale = 7.0,
        acceleration_ramp_k = 0.55,
        max_step_scale = 7.0,
        max_backlog_px = 3600.0,
        easing = "easeOutCubic",
        timer_interval_ms = 8.0,
        enabled = true,
        reverse_direction = false,
        enable_horizontal = true,
        debug = false,
    },
    normal = {
        step_size_px = 90.0,
        pulse_scale = 2.5,
        animation_time_ms = 320.0,
        acceleration_delta_ms = 80.0,
        acceleration_scale = 4.0,
        acceleration_ramp_k = 0.45,
        max_step_scale = 4.0,
        max_backlog_px = 2600.0,
        easing = "easeOutCubic",
        timer_interval_ms = 8.0,
        enabled = true,
        reverse_direction = false,
        enable_horizontal = true,
        debug = false,
    },
    aggressive = {
        step_size_px = 90.0,
        pulse_scale = 4.0,
        animation_time_ms = 360.0,
        acceleration_delta_ms = 70.0,
        acceleration_scale = 7.0,
        acceleration_ramp_k = 0.55,
        max_step_scale = 7.0,
        max_backlog_px = 3600.0,
        easing = "easeOutCubic",
        timer_interval_ms = 8.0,
        enabled = true,
        reverse_direction = false,
        enable_horizontal = true,
        debug = false,
    },
    precision = {
        step_size_px = 70.0,
        pulse_scale = 1.8,
        animation_time_ms = 260.0,
        acceleration_delta_ms = 90.0,
        acceleration_scale = 3.0,
        acceleration_ramp_k = 0.35,
        max_step_scale = 3.0,
        max_backlog_px = 2000.0,
        easing = "easeOutCubic",
        timer_interval_ms = 8.0,
        enabled = true,
        reverse_direction = false,
        enable_horizontal = true,
        debug = false,
    },
}

PRESETS.aggresive = PRESETS.aggressive

local ACTIVE_PRESET = "custom"

local function clone_settings(source)
    local out = {}
    for key, value in pairs(source) do
        out[key] = value
    end
    return out
end

local SETTINGS = clone_settings(PRESETS[ACTIVE_PRESET] or PRESETS.custom)

local function plugin_log_debug(message)
    if SETTINGS.debug then
        libinput:log_debug(message)
    end
end

local WHEEL_UNIT = 120.0
local EPSILON = 0.000001

local ANIMATION_US = SETTINGS.animation_time_ms * 1000.0
local ACCELERATION_DELTA_US = SETTINGS.acceleration_delta_ms * 1000.0
local TIMER_INTERVAL_US = math.floor(SETTINGS.timer_interval_ms * 1000.0 + 0.5)
local HIRES_PER_PX = WHEEL_UNIT / SETTINGS.step_size_px

local REL_WHEEL = evdev.REL_WHEEL
local REL_WHEEL_HI_RES = evdev.REL_WHEEL_HI_RES
local REL_H_WHEEL = evdev.REL_H_WHEEL or evdev.REL_HWHEEL
local REL_H_WHEEL_HI_RES = evdev.REL_H_WHEEL_HI_RES or evdev.REL_HWHEEL_HI_RES

local devices = {}
local timer_armed = false

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    elseif value > max_value then
        return max_value
    end
    return value
end

local function ease(progress)
    if progress <= 0.0 then
        return 0.0
    elseif progress >= 1.0 then
        return 1.0
    end

    if SETTINGS.easing == "linear" then
        return progress
    end

    local inv = 1.0 - progress
    return 1.0 - inv * inv * inv
end

local function trunc_toward_zero(value)
    if value >= 0 then
        return math.floor(value)
    end
    return math.ceil(value)
end

local function ensure_timer_running()
    if not timer_armed then
        timer_armed = true
        libinput:timer_set_relative(TIMER_INTERVAL_US)
    end
end

local function compute_scale(state, timestamp)
    if state.last_input_us ~= 0 and (timestamp - state.last_input_us) <= ACCELERATION_DELTA_US then
        state.combo = state.combo + 1
    else
        state.combo = 1
    end

    state.last_input_us = timestamp

    local target = clamp(SETTINGS.acceleration_scale, 1.0, SETTINGS.max_step_scale)
    if state.combo <= 1 or target <= 1.0 then
        return 1.0
    end

    local factor = 1.0 - math.exp(-SETTINGS.acceleration_ramp_k * (state.combo - 1))
    local scale = 1.0 + (target - 1.0) * factor
    return clamp(scale, 1.0, SETTINGS.max_step_scale)
end

local function add_impulse(list, distance_px, timestamp)
    if math.abs(distance_px) <= EPSILON then
        return
    end

    if #list >= 64 then
        local tail = list[#list]
        tail.total = tail.total + distance_px
        return
    end

    list[#list + 1] = {
        start_us = timestamp,
        total = distance_px,
        emitted = 0.0,
    }
end

local function queue_distance(state, axis, distance_px, timestamp)
    if math.abs(distance_px) <= EPSILON then
        return
    end

    if axis == "v" then
        local clamped_backlog = clamp(state.backlog_v + distance_px, -SETTINGS.max_backlog_px, SETTINGS.max_backlog_px)
        local accepted = clamped_backlog - state.backlog_v
        if math.abs(accepted) <= EPSILON then
            return
        end
        state.backlog_v = clamped_backlog
        add_impulse(state.impulses_v, accepted, timestamp)
    else
        local clamped_backlog = clamp(state.backlog_h + distance_px, -SETTINGS.max_backlog_px, SETTINGS.max_backlog_px)
        local accepted = clamped_backlog - state.backlog_h
        if math.abs(accepted) <= EPSILON then
            return
        end
        state.backlog_h = clamped_backlog
        add_impulse(state.impulses_h, accepted, timestamp)
    end

    state.active = true
    ensure_timer_running()
end

local function release_axis(state, axis, now_us)
    local impulses = axis == "v" and state.impulses_v or state.impulses_h
    local released = 0.0
    local index = 1

    while index <= #impulses do
        local impulse = impulses[index]
        local progress = (now_us - impulse.start_us) / ANIMATION_US
        local target

        if progress >= 1.0 then
            target = impulse.total
        elseif progress <= 0.0 then
            target = 0.0
        else
            target = impulse.total * ease(progress)
        end

        local delta = target - impulse.emitted
        if delta ~= 0.0 then
            impulse.emitted = target
            released = released + delta
        end

        if progress >= 1.0 then
            impulses[index] = impulses[#impulses]
            impulses[#impulses] = nil
        else
            index = index + 1
        end
    end

    if axis == "v" then
        state.backlog_v = state.backlog_v - released
    else
        state.backlog_h = state.backlog_h - released
    end

    return released
end

local function px_to_hires(delta_px, residual)
    local value = delta_px * HIRES_PER_PX + residual
    local hires_delta = trunc_toward_zero(value)
    local next_residual = value - hires_delta
    return hires_delta, next_residual
end

local function emit_axis_events(state, events, axis, hires_delta)
    if hires_delta == 0 then
        return
    end

    if axis == "v" then
        if state.has_rel_wheel_hires then
            events[#events + 1] = { usage = REL_WHEEL_HI_RES, value = hires_delta }
        end

        if state.has_rel_wheel then
            state.detent_carry_v = state.detent_carry_v + hires_delta
            local detents = trunc_toward_zero(state.detent_carry_v / WHEEL_UNIT)
            if detents ~= 0 then
                state.detent_carry_v = state.detent_carry_v - detents * WHEEL_UNIT
                events[#events + 1] = { usage = REL_WHEEL, value = detents }
            end
        end
    else
        if state.has_rel_hwheel_hires then
            events[#events + 1] = { usage = REL_H_WHEEL_HI_RES, value = hires_delta }
        end

        if state.has_rel_hwheel then
            state.detent_carry_h = state.detent_carry_h + hires_delta
            local detents = trunc_toward_zero(state.detent_carry_h / WHEEL_UNIT)
            if detents ~= 0 then
                state.detent_carry_h = state.detent_carry_h - detents * WHEEL_UNIT
                events[#events + 1] = { usage = REL_H_WHEEL, value = detents }
            end
        end
    end
end

local function timer_expired(now_us)
    local still_active = false

    for device, state in pairs(devices) do
        if state.active then
            local released_v_px = release_axis(state, "v", now_us)
            local released_h_px = release_axis(state, "h", now_us)

            local hires_v
            hires_v, state.residual_v = px_to_hires(released_v_px, state.residual_v)

            local hires_h
            hires_h, state.residual_h = px_to_hires(released_h_px, state.residual_h)

            local out = {}
            emit_axis_events(state, out, "v", hires_v)
            emit_axis_events(state, out, "h", hires_h)

            if #out > 0 then
                device:append_frame(out)
            end

            state.active = (#state.impulses_v > 0) or (#state.impulses_h > 0)
            if state.active then
                still_active = true
            end
        end
    end

    if still_active then
        libinput:timer_set_relative(TIMER_INTERVAL_US)
    else
        timer_armed = false
    end
end

local function is_scroll_usage(usage)
    return usage == REL_WHEEL
        or usage == REL_WHEEL_HI_RES
        or usage == REL_H_WHEEL
        or usage == REL_H_WHEEL_HI_RES
end

local function handle_frame(device, frame, timestamp)
    if not SETTINGS.enabled then
        return nil
    end

    local state = devices[device]
    if not state then
        return nil
    end

    local seen_scroll = false
    local seen_v_hires = false
    local seen_h_hires = false
    local saw_v = false
    local saw_h = false

    local hires_v = 0
    local hires_h = 0
    local detent_v = 0
    local detent_h = 0
    for _, event in ipairs(frame) do
        local usage = event.usage
        if usage == REL_WHEEL_HI_RES then
            seen_scroll = true
            seen_v_hires = true
            saw_v = true
            hires_v = hires_v + event.value
        elseif usage == REL_H_WHEEL_HI_RES then
            seen_scroll = true
            seen_h_hires = true
            saw_h = true
            hires_h = hires_h + event.value
        elseif usage == REL_WHEEL then
            seen_scroll = true
            saw_v = true
            detent_v = detent_v + event.value
        elseif usage == REL_H_WHEEL then
            seen_scroll = true
            saw_h = true
            detent_h = detent_h + event.value
        end
    end

    if not seen_scroll then
        return nil
    end

    local steps_v = seen_v_hires and (hires_v / WHEEL_UNIT) or detent_v
    local steps_h = SETTINGS.enable_horizontal and (seen_h_hires and (hires_h / WHEEL_UNIT) or detent_h) or 0

    local direction_sign = SETTINGS.reverse_direction and -1.0 or 1.0
    steps_v = steps_v * direction_sign * SETTINGS.pulse_scale
    steps_h = steps_h * direction_sign * SETTINGS.pulse_scale

    if steps_v ~= 0 or steps_h ~= 0 then
        local scale = compute_scale(state, timestamp)
        queue_distance(state, "v", steps_v * SETTINGS.step_size_px * scale, timestamp)
        queue_distance(state, "h", steps_h * SETTINGS.step_size_px * scale, timestamp)
    end

    local out = {}
    for _, event in ipairs(frame) do
        local usage = event.usage
        local is_v_scroll = usage == REL_WHEEL or usage == REL_WHEEL_HI_RES
        local is_h_scroll = usage == REL_H_WHEEL or usage == REL_H_WHEEL_HI_RES

        local drop_event = false
        if is_v_scroll and saw_v then
            drop_event = true
        elseif is_h_scroll and SETTINGS.enable_horizontal and saw_h then
            drop_event = true
        end

        if not drop_event then
            out[#out + 1] = event
        end
    end
    return out
end

local function handle_removed(device)
    devices[device] = nil
end

local function new_device(device)
    local usages = device:usages()

    local has_rel_wheel = REL_WHEEL and usages[REL_WHEEL] and true or false
    local has_rel_wheel_hires = REL_WHEEL_HI_RES and usages[REL_WHEEL_HI_RES] and true or false
    local has_rel_hwheel = REL_H_WHEEL and usages[REL_H_WHEEL] and true or false
    local has_rel_hwheel_hires = REL_H_WHEEL_HI_RES and usages[REL_H_WHEEL_HI_RES] and true or false

    if not (has_rel_wheel or has_rel_wheel_hires or has_rel_hwheel or has_rel_hwheel_hires) then
        plugin_log_debug("smooth-scroll skip (no wheel axes): " .. device:name())
        return
    end

    devices[device] = {
        has_rel_wheel = has_rel_wheel,
        has_rel_wheel_hires = has_rel_wheel_hires,
        has_rel_hwheel = has_rel_hwheel,
        has_rel_hwheel_hires = has_rel_hwheel_hires,
        impulses_v = {},
        impulses_h = {},
        backlog_v = 0.0,
        backlog_h = 0.0,
        residual_v = 0.0,
        residual_h = 0.0,
        detent_carry_v = 0.0,
        detent_carry_h = 0.0,
        combo = 1,
        last_input_us = 0,
        active = false,
    }

    device:connect("evdev-frame", handle_frame)
    device:connect("device-removed", handle_removed)

    libinput:log_info("smooth-scroll active on: " .. device:name())
end

local version = libinput:register({1})
if version == 1 then
    libinput:connect("new-evdev-device", new_device)
    libinput:connect("timer-expired", timer_expired)
    libinput:log_info("smooth-scroll plugin initialized (API v1)")
end
