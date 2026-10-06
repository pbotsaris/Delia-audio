pub const AlsaError = error{
    device_init,
    device_deinit,
    device_list,
    device_prepare,
    device_start,
    device_unexpected,

    xrun,
    suspended,
    unexpected,
    timeout,

    card_not_found,
    card_out_of_bounds,
    card_invalid_settings,
    card_invalid_support_settings,

    playback_out_of_bounds,
    playback_not_found,
    capture_out_of_bounds,
    capture_not_found,
    invalid_identifier,
};
