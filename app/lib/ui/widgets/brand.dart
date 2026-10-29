// Brand lockup for the top-right of every main screen: the app icon followed
// by the "KARAOKE BATTLE" logotype. Colours come from the app icon: the deep
// violet -> magenta background, the white microphone and the green / yellow /
// red pitch bars (scripts/make_icon.py).
import 'package:flutter/material.dart';

class Brand {
  Brand._();
  static const violet = Color(0xFFB48CFF); // light tint of the icon's violet
  static const magenta = Color(0xFFFF4FA3); // light tint of the icon's magenta
  static const green = Color(0xFF4CAF50);
  static const yellow = Color(0xFFFFEB3B);
  static const red = Color(0xFFF44336);
}

/// Horizontal logo: icon + logotype. [height] is the icon size; the logotype
/// scales with it.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.height = 34});
  final double height;

  @override
  Widget build(BuildContext context) {
    final fs = height * 0.52;
    final word = TextStyle(
      fontSize: fs,
      fontWeight: FontWeight.w900,
      fontStyle: FontStyle.italic,
      letterSpacing: fs * 0.08,
      height: 1.0,
    );
    return Semantics(
      label: 'Karaoke Battle',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height * 0.24),
              boxShadow: [BoxShadow(color: Brand.magenta.withValues(alpha: 0.35), blurRadius: height * 0.3)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(height * 0.24),
              child: Image.asset('assets/images/app_icon.png', width: height, height: height, filterQuality: FilterQuality.medium),
            ),
          ),
          SizedBox(width: height * 0.28),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (r) => const LinearGradient(colors: [Brand.violet, Brand.magenta]).createShader(r),
                    child: Text('KARAOKE', style: word),
                  ),
                  SizedBox(width: fs * 0.3),
                  Text('BATTLE', style: word.copyWith(color: Colors.white)),
                ],
              ),
              SizedBox(height: height * 0.1),
              // The icon's pitch bars, as a small underline.
              _PitchBars(height: height * 0.09, unit: fs * 0.62),
            ],
          ),
        ],
      ),
    );
  }
}

class _PitchBars extends StatelessWidget {
  const _PitchBars({required this.height, required this.unit});
  final double height;
  final double unit;

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, Color c, {double dy = 0}) => Padding(
          padding: EdgeInsets.only(right: unit * 0.25, top: dy < 0 ? 0 : dy, bottom: dy < 0 ? -dy : 0),
          child: Container(
            width: unit * w,
            height: height,
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(height)),
          ),
        );
    // Same order as the icon: green, yellow, green, red at slightly
    // different heights, like notes on a roll.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar(1.6, Brand.green, dy: height),
        bar(2.4, Brand.yellow),
        bar(1.2, Brand.green, dy: height),
        bar(2.0, Brand.red, dy: height * 2),
      ],
    );
  }
}

/// [BrandLockup] with the spacing used in AppBar actions.
class AppBarBrand extends StatelessWidget {
  const AppBarBrand({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(left: 12, right: 16),
        child: Center(child: BrandLockup()),
      );
}
