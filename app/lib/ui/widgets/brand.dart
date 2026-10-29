// Brand lockup for the top-right of every main screen: the app icon followed
// by the "KARAOKE BATTLE" logotype. Colours come from the app icon: the deep
// violet -> magenta background and the white microphone (scripts/make_icon.py).
import 'package:flutter/material.dart';

class Brand {
  Brand._();
  static const violet = Color(0xFFB48CFF); // light tint of the icon's violet
  static const magenta = Color(0xFFFF4FA3); // light tint of the icon's magenta
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
        ],
      ),
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
