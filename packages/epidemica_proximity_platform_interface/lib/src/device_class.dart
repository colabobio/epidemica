/// Hardware class of a device.
///
/// This is not descriptive metadata: the mapping from received signal strength to
/// distance depends on the transmitting hardware, so both sides' class is needed to
/// interpret or re-derive a proximity estimate.
enum DeviceClass {
  ios,
  android,

  /// The class could not be determined. Carried through to the observation as `null`
  /// rather than defaulted, so that downstream analysis can see the uncertainty instead
  /// of inheriting a guess.
  unknown;

  /// `null` for [DeviceClass.unknown], matching the contract's `deviceClass` enum.
  String? toJson() => this == DeviceClass.unknown ? null : name;

  static DeviceClass fromJson(Object? value) => switch (value) {
    'ios' => DeviceClass.ios,
    'android' => DeviceClass.android,
    _ => DeviceClass.unknown,
  };
}
