local mp = require 'mp'
local msg = require 'mp.msg'

-- ========== 手势参数 ==========
local MOVE_THRESHOLD = 45
local VERTICAL_SWIPE_THRESHOLD = 32   -- 竖直滑动触发距离（320x170 屏约 19% 屏高）
local TAP_MAX_DURATION = 0.3
local LONG_PRESS_THRESHOLD = 0.5
local SEEK_SENSITIVITY = 0.2
local DOUBLE_SPEED = 1.5
local MOVE_CHECK_INTERVAL = 0.03

-- ========== 按钮参数 ==========
local BTN_SIZE = 21
local CLOSE_BTN_SIZE = 23
local BTN_MARGIN = 10
local BTN_TOP = 25
local BTN_RADIUS = 4
local BTN_GAP = 10
local LEFT_BTN_X = 16

-- 发布按钮几何（真实像素），modernx 的 touch_extra_buttons 读取同一份，
-- 保证 OSC 上的 ↺/+ 与缩放模式下本脚本画的按钮位置一致，改这里一处即可。
mp.set_property_native("user-data/touch_control/btn-geometry", {
    size   = BTN_SIZE,
    x      = LEFT_BTN_X,
    top    = BTN_TOP,
    gap    = BTN_GAP,
    radius = BTN_RADIUS,
})

-- ========== 按钮状态 ==========
local controls_overlay = mp.create_osd_overlay("ass-events")
local modernx_visible = false
local close_button_down = false
local zoom_button_down = false
local zoom_out_button_down = false
local reset_button_down = false
local zoom_mode = false
local zoom_level = 0
local zoom_pan_down = false
local pan_start_pos = { x = 0, y = 0 }
local pan_start_x = 0
local pan_start_y = 0

-- ========== 手势状态 ==========
local last_tap_time = 0
local touch_down = false
local is_showing_progress = false
local vertical_swipe_done = false
local long_press_active = false
local keep_osd_display = false
local moved_enough = false

local start_time = 0
local start_pos = { x = 0, y = 0 }
local current_pos = { x = 0, y = 0 }
local video_pos_on_touch = 0
local video_duration = 0

local long_press_timer = nil
local speed_osd_timer = nil
local move_check_timer = nil

local osd_shield_active

local GESTURE_AREAS = {
    "touch_gesture_area",
    "touch_gesture_area_left_top",
    "touch_gesture_area_left_side",
    "touch_gesture_area_left_bottom",
}

-- ========== 工具函数 ==========
local function now()
    return mp.get_time()
end

local function get_mouse()
    local x, y = mp.get_mouse_pos()
    return { x = x or current_pos.x or 0, y = y or current_pos.y or 0 }
end

local function cancel_long_press()
    if long_press_timer then
        long_press_timer:kill()
        long_press_timer = nil
    end
end

local function in_rect(pos, x1, y1, x2, y2)
    return pos.x >= x1 and pos.x <= x2 and pos.y >= y1 and pos.y <= y2
end

local function close_button_rect()
    local w = mp.get_osd_size()
    if not w or w <= 0 then return nil end
    local x1 = w - BTN_MARGIN - CLOSE_BTN_SIZE
    local y1 = BTN_MARGIN
    return x1, y1, x1 + CLOSE_BTN_SIZE, y1 + CLOSE_BTN_SIZE
end

local function reset_button_rect()
    local x1 = LEFT_BTN_X
    local y1 = BTN_TOP
    return x1, y1, x1 + BTN_SIZE, y1 + BTN_SIZE
end

local function zoom_button_rect()
    local x1 = LEFT_BTN_X
    local y1 = BTN_TOP + BTN_SIZE + BTN_GAP
    return x1, y1, x1 + BTN_SIZE, y1 + BTN_SIZE
end

local function zoom_out_button_rect()
    local x1 = LEFT_BTN_X
    local y1 = BTN_TOP + (BTN_SIZE + BTN_GAP) * 2
    return x1, y1, x1 + BTN_SIZE, y1 + BTN_SIZE
end

local function close_visible()
    -- 缩放模式下 OSC 被禁用，若不显示 × 就没有退出播放器的入口
    return modernx_visible or zoom_mode
end

local function left_buttons_visible()
    return zoom_mode
end

local function in_close_button(pos)
    if not close_visible() then return false end
    local x1, y1, x2, y2 = close_button_rect()
    return x1 and in_rect(pos, x1, y1, x2, y2)
end

local function in_zoom_button(pos)
    if not left_buttons_visible() then return false end
    local x1, y1, x2, y2 = zoom_button_rect()
    return in_rect(pos, x1, y1, x2, y2)
end

local function in_zoom_out_button(pos)
    if not left_buttons_visible() or zoom_level <= 0 then return false end
    local x1, y1, x2, y2 = zoom_out_button_rect()
    return in_rect(pos, x1, y1, x2, y2)
end

local function in_reset_button(pos)
    if not left_buttons_visible() then return false end
    local x1, y1, x2, y2 = reset_button_rect()
    return in_rect(pos, x1, y1, x2, y2)
end

local function round_rect_ass(x1, y1, x2, y2, r)
    return string.format(
        "m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d ",
        x1 + r, y1,
        x2 - r, y1,
        x2, y1, x2, y1, x2, y1 + r,
        x2, y2 - r,
        x2, y2, x2, y2, x2 - r, y2,
        x1 + r, y2,
        x1, y2, x1, y2, x1, y2 - r,
        x1, y1 + r,
        x1, y1, x1, y1, x1 + r, y1
    )
end

local function button_ass(x1, y1, x2, y2, label, fs)
    local cx = (x1 + x2) / 2
    local cy = (y1 + y2) / 2
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0}{\\1c&H202020&\\alpha&H70&\\p1}%s{\\p0}\n" ..
        "{\\an5\\bord0\\shad0\\1c&HFFFFFF&\\fs%d\\pos(%f,%f)}%s\n",
        round_rect_ass(x1, y1, x2, y2, BTN_RADIUS), fs, cx, cy, label
    )
end

local function disable_mouse_area(name)
    mp.set_mouse_area(0, 0, 0, 0, name)
    mp.disable_key_bindings(name)
end

local function set_enabled_mouse_area(name, x1, y1, x2, y2)
    if x2 > x1 and y2 > y1 then
        mp.set_mouse_area(x1, y1, x2, y2, name)
        mp.enable_key_bindings(name, "allow-vo-dragging+allow-hide-cursor")
    else
        disable_mouse_area(name)
    end
end

local function update_mouse_areas()
    local w, h = mp.get_osd_size()
    if not w or not h or w <= 0 or h <= 0 then return end

    if not zoom_mode then
        if osd_shield_active() then
            -- OSC 可见（如暂停时）：彻底释放手势层，把点击让给 ModernX 的
            -- input 区（控制条控件）与 showhide 区（视频区域点按/滑动，见
            -- modernx 的 touch 处理），避免手势层吞掉进度条等控件。
            for _, name in ipairs(GESTURE_AREAS) do
                disable_mouse_area(name)
            end
        else
            set_enabled_mouse_area("touch_gesture_area", 0, 0, w, h)
            disable_mouse_area("touch_gesture_area_left_top")
            disable_mouse_area("touch_gesture_area_left_side")
            disable_mouse_area("touch_gesture_area_left_bottom")
        end
    else
        for _, name in ipairs(GESTURE_AREAS) do
            disable_mouse_area(name)
        end
    end

    if left_buttons_visible() then
        local x1, y1, x2, y2 = reset_button_rect()
        local zx1, zy1, zx2, zy2 = zoom_button_rect()
        local right = math.max(x2, zx2)
        local bottom = math.max(y2, zy2)
        if zoom_level > 0 then
            local ox1, oy1, ox2, oy2 = zoom_out_button_rect()
            x1 = math.min(x1, ox1)
            y1 = math.min(y1, oy1)
            right = math.max(right, ox2)
            bottom = math.max(bottom, oy2)
        end
        mp.set_mouse_area(math.min(x1, zx1), math.min(y1, zy1), right, bottom, "touch_left_buttons")
        mp.enable_key_bindings("touch_left_buttons")
    else
        mp.set_mouse_area(0, 0, 0, 0, "touch_left_buttons")
        mp.disable_key_bindings("touch_left_buttons")
    end

    if close_visible() then
        local x1, y1, x2, y2 = close_button_rect()
        mp.set_mouse_area(x1, y1, x2, y2, "touch_close_button")
        mp.enable_key_bindings("touch_close_button")
    else
        mp.set_mouse_area(0, 0, 0, 0, "touch_close_button")
        mp.disable_key_bindings("touch_close_button")
    end

    if zoom_mode then
        -- 避开左侧按钮区域，否则全屏平移绑定会抢走按钮点击。
        local _, _, button_right = reset_button_rect()
        mp.set_mouse_area(button_right + BTN_MARGIN, 0, w, h, "touch_zoom_pan")
        mp.enable_key_bindings("touch_zoom_pan", "allow-vo-dragging+allow-hide-cursor")
    else
        mp.set_mouse_area(0, 0, 0, 0, "touch_zoom_pan")
        mp.disable_key_bindings("touch_zoom_pan")
    end
end

local draw_controls

local resync_timer = nil
local function schedule_resync()
    if resync_timer then return end
    resync_timer = mp.add_timeout(0.2, function()
        resync_timer = nil
        draw_controls()
    end)
end

draw_controls = function()
    local w, h = mp.get_osd_size()
    if not w or w <= 0 or not h or h <= 0 then
        -- OSD 尺寸暂时无效（启动、VO 重配置瞬间）。此时收到的 shield/可见性
        -- 变化不能丢弃，否则手势层可能残留在输入栈顶吞掉 OSC 的点击。
        schedule_resync()
        return
    end

    local ass = ""

    if close_visible() then
        local x1, y1, x2, y2 = close_button_rect()
        ass = ass .. button_ass(x1, y1, x2, y2, "×", 17)
    end

    if left_buttons_visible() then
        local x1, y1, x2, y2 = reset_button_rect()
        ass = ass .. button_ass(x1, y1, x2, y2, "↺", 14)

        x1, y1, x2, y2 = zoom_button_rect()
        ass = ass .. button_ass(x1, y1, x2, y2, "+", 16)

        if zoom_level > 0 then
            x1, y1, x2, y2 = zoom_out_button_rect()
            ass = ass .. button_ass(x1, y1, x2, y2, "−", 16)
        end
    end

    update_mouse_areas()

    if ass == "" then
        controls_overlay:remove()
        return
    end

    controls_overlay.res_x = mp.get_property_number("osd-width", 0)
    controls_overlay.res_y = mp.get_property_number("osd-height", 0)
    controls_overlay.z = 2000
    controls_overlay.data = ass
    controls_overlay:update()
end

local function hide_controls_if_needed()
    draw_controls()
end

local function enter_zoom_mode()
    zoom_mode = true
    zoom_level = zoom_level + 0.25
    mp.set_property_number("video-zoom", zoom_level)
    mp.commandv("script-message-to", "modernx", "touch_zoom_mode", "yes")
    modernx_visible = false
    draw_controls()
end

local function zoom_out()
    if not zoom_mode then return end
    zoom_level = math.max(0, zoom_level - 0.25)
    mp.set_property_number("video-zoom", zoom_level)
    draw_controls()
end

local function reset_zoom_mode()
    zoom_mode = false
    zoom_level = 0
    mp.set_property_number("video-zoom", 0)
    mp.set_property_number("video-pan-x", 0)
    mp.set_property_number("video-pan-y", 0)
    mp.commandv("script-message-to", "modernx", "touch_zoom_mode", "no")
    draw_controls()
end

osd_shield_active = function()
    return mp.get_property_bool("user-data/modernx/touch-shield", false)
        or mp.get_property_bool("user-data/modernx/osc-visible", false)
        or modernx_visible
end

local function format_time(seconds)
    if not seconds or seconds < 0 then return "00:00" end
    seconds = math.floor(seconds)
    local hh = math.floor(seconds / 3600)
    local mm = math.floor((seconds % 3600) / 60)
    local ss = math.floor(seconds % 60)
    if hh > 0 then
        return string.format("%d:%02d:%02d", hh, mm, ss)
    else
        return string.format("%02d:%02d", mm, ss)
    end
end

local function show_progress(target_time)
    local duration = mp.get_property_number("duration", 0)
    local text
    if duration <= 0 then
        text = string.format("跳转: %s", format_time(target_time))
    else
        text = string.format("跳转: %s / %s", format_time(target_time), format_time(duration))
    end
    mp.osd_message(text, 0.5)
end

local function stop_speed_mode()
    keep_osd_display = false
    if speed_osd_timer then
        speed_osd_timer:kill()
        speed_osd_timer = nil
    end
    mp.set_property_number("speed", 1.0)
    mp.osd_message("1x", 0.8)
    long_press_active = false
end

local function process_touch_move()
    current_pos = get_mouse()

    if zoom_mode then
        if zoom_pan_down then
            local w, h = mp.get_osd_size()
            if w and h and w > 0 and h > 0 then
                -- video-pan 的单位是缩放后视频尺寸的比例，video-zoom 是 log2 倍率，
                -- 必须除以 2^zoom，否则放大越多画面跟手位移偏差越大。
                local scale = 2 ^ (mp.get_property_number("video-zoom", zoom_level) or zoom_level)
                local dx = current_pos.x - pan_start_pos.x
                local dy = current_pos.y - pan_start_pos.y
                mp.set_property_number("video-pan-x", pan_start_x + dx / (w * scale))
                mp.set_property_number("video-pan-y", pan_start_y + dy / (h * scale))
            end
        end
        return
    end

    if not touch_down or long_press_active then return end

    local delta_x = current_pos.x - start_pos.x
    local delta_y = current_pos.y - start_pos.y
    local abs_x = math.abs(delta_x)
    local abs_y = math.abs(delta_y)

    if abs_x >= MOVE_THRESHOLD or abs_y >= MOVE_THRESHOLD then
        moved_enough = true
        cancel_long_press()
    end

    -- 竖直滑动：上滑隐藏 OSD、下滑显示 OSD（缩放模式下已提前返回，不生效）。
    -- 要求竖直分量明显占优（abs_y > abs_x），避免与水平快进/点按混淆。
    if not vertical_swipe_done and not is_showing_progress
        and abs_y > VERTICAL_SWIPE_THRESHOLD and abs_y > abs_x then
        vertical_swipe_done = true
        moved_enough = true
        cancel_long_press()
        if delta_y < 0 then
            mp.commandv("script-message-to", "modernx", "touch_osd_hide")
        else
            mp.commandv("script-message-to", "modernx", "touch_osd_show")
        end
    end

    if not is_showing_progress and not vertical_swipe_done
        and abs_x > MOVE_THRESHOLD and abs_y < (MOVE_THRESHOLD + 50) then
        is_showing_progress = true
    end

    if is_showing_progress then
        local target_time = video_pos_on_touch + delta_x * SEEK_SENSITIVITY
        if video_duration > 0 then
            target_time = math.max(0, math.min(target_time, video_duration))
        end
        show_progress(target_time)
    end
end

local function start_speed_mode()
    if zoom_mode then return end
    if not touch_down or long_press_active or moved_enough then return end

    current_pos = get_mouse()
    local dx = math.abs(current_pos.x - start_pos.x)
    local dy = math.abs(current_pos.y - start_pos.y)

    if dx < MOVE_THRESHOLD and dy < MOVE_THRESHOLD then
        long_press_active = true
        keep_osd_display = true
        mp.set_property_number("speed", DOUBLE_SPEED)
        mp.osd_message(DOUBLE_SPEED .. "x", 0.8)

        speed_osd_timer = mp.add_periodic_timer(0.8, function()
            if keep_osd_display then
                mp.osd_message(DOUBLE_SPEED .. "x", 0.8)
            end
        end)
    end
end

local function process_touch_down()
    current_pos = get_mouse()

    touch_down = false
    zoom_pan_down = false
    cancel_long_press()
    if move_check_timer then
        move_check_timer:kill()
        move_check_timer = nil
    end

    close_button_down = false
    zoom_button_down = false
    zoom_out_button_down = false
    reset_button_down = false

    if in_close_button(current_pos) then
        close_button_down = true
        return
    end
    if in_zoom_button(current_pos) then
        zoom_button_down = true
        return
    end
    if in_zoom_out_button(current_pos) then
        zoom_out_button_down = true
        return
    end
    if in_reset_button(current_pos) then
        reset_button_down = true
        return
    end

    if zoom_mode then
        zoom_pan_down = true
        pan_start_pos = { x = current_pos.x, y = current_pos.y }
        pan_start_x = mp.get_property_number("video-pan-x", 0) or 0
        pan_start_y = mp.get_property_number("video-pan-y", 0) or 0
        return
    end

    -- 防御：OSC 可见时手势层本应已被禁用。若因启动竞态（尺寸无效时错过一次
    -- 区域更新）仍收到按下事件，忽略它并立即重新同步鼠标区域，
    -- 把点击让给 ModernX，避免整个会话 OSC 都点不动。
    if osd_shield_active() then
        draw_controls()
        return
    end

    touch_down = true
    is_showing_progress = false
    vertical_swipe_done = false
    long_press_active = false
    keep_osd_display = false
    moved_enough = false
    cancel_long_press()

    if speed_osd_timer then
        speed_osd_timer:kill()
        speed_osd_timer = nil
    end
    if move_check_timer then
        move_check_timer:kill()
        move_check_timer = nil
    end

    start_pos = { x = current_pos.x, y = current_pos.y }
    start_time = now()
    video_pos_on_touch = mp.get_property_number("time-pos", 0) or 0
    video_duration = mp.get_property_number("duration", 0) or 0

    move_check_timer = mp.add_periodic_timer(MOVE_CHECK_INTERVAL, process_touch_move)
    long_press_timer = mp.add_timeout(LONG_PRESS_THRESHOLD, start_speed_mode)
end

local function process_touch_up()
    current_pos = get_mouse()

    if zoom_pan_down then
        zoom_pan_down = false
        return
    end

    if close_button_down then
        close_button_down = false
        if in_close_button(current_pos) then mp.commandv("quit") end
        return
    end

    if zoom_button_down then
        zoom_button_down = false
        if in_zoom_button(current_pos) then enter_zoom_mode() end
        return
    end


    if zoom_out_button_down then
        zoom_out_button_down = false
        if in_zoom_out_button(current_pos) then zoom_out() end
        return
    end

    if reset_button_down then
        reset_button_down = false
        if in_reset_button(current_pos) then reset_zoom_mode() end
        return
    end

    if zoom_mode then return end
    if not touch_down then return end

    touch_down = false
    cancel_long_press()

    if move_check_timer then
        move_check_timer:kill()
        move_check_timer = nil
    end

    if long_press_active then
        stop_speed_mode()
        return
    end

    if is_showing_progress then
        mp.add_timeout(0.05, function() mp.osd_message("", 0.01) end)
    end

    local delta_x = current_pos.x - start_pos.x
    local delta_y = current_pos.y - start_pos.y
    local duration = now() - start_time

    -- 已判定为竖直滑动（OSD 显示/隐藏），抬手时不再触发快进/点按。
    if vertical_swipe_done then
        last_tap_time = 0
        return
    end

    if math.abs(delta_x) > MOVE_THRESHOLD and math.abs(delta_y) < (MOVE_THRESHOLD + 50) then
        mp.commandv("seek", delta_x * SEEK_SENSITIVITY, "relative")
        last_tap_time = 0
        return
    end

    if math.abs(delta_x) < MOVE_THRESHOLD and math.abs(delta_y) < MOVE_THRESHOLD and duration < TAP_MAX_DURATION then
        if mp.get_property_bool("eof-reached", false) then
            -- keep-open 播放完毕停在末帧时，一次点按直接从头播放
            mp.commandv("seek", 0, "absolute-percent")
            mp.commandv("set", "pause", "no")
            mp.osd_message(" ▶", 0.8)
        else
            local paused = mp.get_property_bool("pause", false)
            mp.commandv("cycle", "pause")
            mp.osd_message(paused and " ▶" or " ▍▍", 0.8)
        end
        last_tap_time = now()
        return
    end

    last_tap_time = 0
end

local touch_gesture_bindings = {
    { "mbtn_left", function() process_touch_up() end, function() process_touch_down() end },
    { "mouse_move", function() process_touch_move() end },
}

for _, name in ipairs(GESTURE_AREAS) do
    mp.set_key_bindings(touch_gesture_bindings, name, "force")
end

mp.set_key_bindings({
    { "mbtn_left", function() process_touch_up() end, function() process_touch_down() end },
}, "touch_left_buttons", "force")

mp.set_key_bindings({
    { "mbtn_left", function() process_touch_up() end, function() process_touch_down() end },
}, "touch_close_button", "force")

mp.set_key_bindings({
    { "mbtn_left", function() process_touch_up() end, function() process_touch_down() end },
    { "mouse_move", function() process_touch_move() end },
}, "touch_zoom_pan", "force")

mp.register_script_message("modernx_osc_visible", function(v)
    modernx_visible = (v == "yes")
    hide_controls_if_needed()
end)

mp.observe_property("user-data/modernx/osc-visible", "bool", function(_, v)
    modernx_visible = v == true
    hide_controls_if_needed()
end)

mp.observe_property("user-data/modernx/touch-shield", "bool", function()
    hide_controls_if_needed()
end)

mp.register_script_message("touch_zoom_in", function()
    enter_zoom_mode()
end)

mp.register_script_message("touch_zoom_reset", function()
    reset_zoom_mode()
end)

-- keep-open 模式下播放完毕仍保留窗口；此时必须先退出缩放，恢复 OSC 和关闭按钮。
mp.observe_property("eof-reached", "bool", function(_, reached)
    if reached and zoom_mode then
        reset_zoom_mode()
    end
end)

mp.register_event("end-file", function()
    if zoom_mode then
        reset_zoom_mode()
    end
end)

mp.register_event("start-file", function()
    -- 文件切换不一定经过完整的 mouse-up/end-file 流程，主动清除残留输入状态。
    touch_down = false
    zoom_pan_down = false
    close_button_down = false
    zoom_button_down = false
    zoom_out_button_down = false
    reset_button_down = false
    is_showing_progress = false
    vertical_swipe_done = false
    moved_enough = false
    cancel_long_press()

    if move_check_timer then
        move_check_timer:kill()
        move_check_timer = nil
    end

    if long_press_active then
        stop_speed_mode()
    end

    if zoom_mode then
        reset_zoom_mode()
    else
        draw_controls()
    end
end)

mp.observe_property("osd-width", "number", draw_controls)
mp.observe_property("osd-height", "number", draw_controls)

draw_controls()

msg.info("touch_control.lua loaded")
