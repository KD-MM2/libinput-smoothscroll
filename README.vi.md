# libinput smooth scroll Lua plugin

Plugin này mô phỏng smooth scrolling trên wheel bằng cách:
- chặn sự kiện `REL_WHEEL`/`REL_WHEEL_HI_RES` (và horizontal tương tự) trong `evdev-frame`
- chuyển step thành khoảng cách ảo (`step_size_px`)
- dùng timer của libinput để xả dần backlog theo easing trong `animation_time_ms`
- phát lại sự kiện bằng `append_frame()` dưới dạng `REL_*WHEEL*_HI_RES` (+ discrete khi đủ 120 units)

## Callback/hook sử dụng (theo docs libinput Lua plugins)

- `libinput:register({1})`
- `libinput:connect("new-evdev-device", ...)`
- `libinput:connect("timer-expired", function(now_us) ... end)`
- `device:connect("evdev-frame", function(device, frame, timestamp) ... end)`
- `device:connect("device-removed", function(device) ... end)`
- `device:append_frame(frame)` trong `evdev-frame` hoặc `timer-expired`
- `libinput:timer_set_relative(timeout_us)` để tạo tick scheduler

## Data model

Mỗi device có state:
- `impulses_v`, `impulses_h`: danh sách animation impulse đang chạy
- `backlog_v`, `backlog_h`: backlog ảo còn lại (px)
- `combo`, `last_input_us`: tính acceleration theo chuỗi scroll liên tục
- `residual_v/h`: phần dư khi đổi px -> hi-res integer
- `detent_carry_v/h`: tích lũy để phát discrete `REL_WHEEL` mỗi 120 hi-res units

## Settings hiện tại (hardcoded)

Hiện đã có chọn preset trực tiếp trong code qua:
- bảng `PRESETS`
- `ACTIVE_PRESET` (ví dụ: `"custom"`, `"normal"`, `"aggressive"`, `"precision"`)

Lưu ý: trong code có alias `"aggresive"`.

Trong `smooth_scroll.lua`:
- `step_size_px = 90`
- `pulse_scale = 4.0`
- `animation_time_ms = 360`
- `acceleration_delta_ms = 70`
- `acceleration_scale = 7.0`
- `max_step_scale = 7.0`
- `max_backlog_px = 3600`
- `easing = "easeOutCubic"` (`"linear"` cũng hỗ trợ)
- `enabled = true`
- `reverse_direction = false`
- `enable_horizontal = true`
- `debug = false`

Ghi chú nhanh về hành vi:
- `enabled`: nếu đặt `false` thì plugin đi theo kiểu pass-through (không áp smooth/acceleration).
- `reverse_direction`: đảo chiều cuộn cho cả trục dọc và ngang.
- `enable_horizontal`: nếu đặt `false` thì cuộn ngang được pass-through nguyên bản (chỉ còn smooth cho trục dọc).
- `debug`: nếu đặt `true` plugin sẽ in thêm log debug (ví dụ các device bị skip do thiếu wheel axes).

## Bảng preset gợi ý

Dùng các preset này làm điểm bắt đầu bằng cách sửa bảng `SETTINGS` trong `smooth_scroll.lua`.

| Preset | step_size_px | pulse_scale | animation_time_ms | acceleration_delta_ms | acceleration_scale | acceleration_ramp_k | max_step_scale | max_backlog_px |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Normal | 90 | 2.5 | 320 | 80 | 4.0 | 0.45 | 4.0 | 2600 |
| Aggressive | 90 | 4.0 | 360 | 70 | 7.0 | 0.55 | 7.0 | 3600 |
| Precision | 70 | 1.8 | 260 | 90 | 3.0 | 0.35 | 3.0 | 2000 |

Mẹo chỉnh nhanh:
- Bắt đầu từ `Normal`, rồi chỉnh từng tham số một.
- Nếu cảm giác bị giật/nhảy, giảm `pulse_scale` và/hoặc `acceleration_scale`.
- Nếu cảm giác quá chậm, tăng `pulse_scale` trước khi tăng acceleration.

## Acceleration

Nếu `timestamp - last_input_us <= acceleration_delta_ms`, plugin tăng `combo`.
Scale ramp mượt:

`scale = 1 + (target_scale - 1) * (1 - exp(-k * (combo - 1)))`

Trong đó `target_scale = min(acceleration_scale, max_step_scale)`.

## Trackpad vs wheel

Plugin chỉ đụng các usage `REL_WHEEL*`/`REL_HWHEEL*`, nên input kiểu continuous từ touchpad (thường không đi qua các usage này) được pass-through.

## Cài đặt / enable

### 1) Copy plugin

```bash
sudo mkdir -p /etc/libinput/plugins
sudo cp smooth_scroll.lua /etc/libinput/plugins/20-smooth-scroll.lua
```

### 2) Bật plugin system

Phụ thuộc compositor/libinput caller. Theo docs, plugin không tự bật nếu caller không gọi load plugin system.

Để test độc lập:

```bash
sudo libinput debug-events --enable-plugins --verbose
```

Bạn nên thấy log:
- `smooth-scroll plugin initialized (API v1)`
- `smooth-scroll active on: <device-name>` cho chuột/wheel tương thích
- `smooth-scroll skip (no wheel axes): <device-name>` cho device không có wheel axis

### 3) Reload session

Logout/login hoặc reboot để compositor nạp lại libinput (nếu compositor của bạn hỗ trợ plugin).

## Debug

- Dùng log mức verbose:
  - `sudo libinput debug-events --enable-plugins --verbose`
- Nếu không thấy log plugin:
  - kiểm tra file nằm trong `/etc/libinput/plugins/`
  - kiểm tra compositor có hỗ trợ load plugin hay không

### Trường hợp plugin luôn báo `skip (no wheel axes)`

Nếu `debug-events` hiển thị device có capability kiểu:

- `cap:p ... scroll-button`

thì đó thường là **button-scrolling do libinput synthesize** (tạo ở libinput core), không phải wheel axis thật từ kernel. Ở tầng plugin (evdev), không có `REL_WHEEL`/`REL_WHEEL_HI_RES` để can thiệp, nên plugin này sẽ skip đúng như log.

Kiểm tra nhanh thiết bị có wheel axis thật hay không:

```bash
sudo libinput list-devices
```

và/hoặc dùng `evtest` trên đúng `/dev/input/eventX` của chuột:

```bash
sudo evtest /dev/input/eventX
```

Nếu không thấy `REL_WHEEL` hoặc `REL_WHEEL_HI_RES`, smooth-scroll kiểu này không áp dụng được cho thiết bị đó.

## Test plan

### Test 1: 1 nấc wheel
- Cuộn đúng 1 nấc.
- Kỳ vọng: event không nhảy 1 phát lớn, mà được xả thành nhiều hi-res chunk trong khoảng ~360ms.
- Tổng lượng xả tiệm cận `~90px` (đơn vị ảo), tương đương ~120 hi-res units trước khi áp easing/rounding.

### Test 2: cuộn liên tục (accel)
- Cuộn nhanh nhiều nấc, giữ khoảng cách giữa nấc <= 70ms.
- Kỳ vọng: `combo` tăng, scale tăng dần lên gần `7x`, không nhảy đột ngột.
- Dừng cuộn >70ms rồi cuộn lại: scale reset về gần 1.0.

### Test 3: backlog/coalescing
- Cuộn nhanh khi animation cũ chưa xong.
- Kỳ vọng: backlog cộng dồn, animation không reset giật; chuyển động vẫn liên tục.
- Backlog không vượt `max_backlog_px`.

### Test 4: CPU/overhead
- Chạy `top`/`htop` khi cuộn liên tục.
- Kỳ vọng: CPU overhead thấp, không tăng đột biến; không lag input path.

## Giới hạn kỹ thuật quan trọng

- API evdev không có đơn vị pixel thật, chỉ có wheel units integer.
- Smooth ở đây là phát nhiều `HI_RES` events theo thời gian, không phải gửi pixel delta trực tiếp.
- Với thiết bị không có `REL_*_HI_RES`, smooth bị giới hạn vì chỉ có discrete detent events.

## Next development

Hướng phát triển tiếp theo là tìm và hoàn thiện một giải pháp GUI thực dụng để cấu hình dễ hơn.

Định hướng dự kiến:
- Có giao diện nhẹ để chỉnh preset mà không cần sửa tay `smooth_scroll.lua`.
- Hỗ trợ chuyển profile nhanh (`custom`, `normal`, `aggressive`, `precision`).
- Có hướng dẫn apply an toàn và kiểm tra hợp lệ cơ bản cho các tham số số.
- Giữ phần logic plugin tối giản, ổn định; phần tiện dụng UX sẽ nằm ở tooling/tài liệu.
