import 'package:flutter/material.dart';

class Icons8Icon extends StatelessWidget {
  const Icons8Icon(
    this.name, {
    super.key,
    this.size = 20,
    this.color,
  });

  const Icons8Icon.bot({
    super.key,
    this.size = 20,
    this.color,
  }) : name = 'icons8-bot-48';

  const Icons8Icon.ai({
    super.key,
    this.size = 20,
    this.color,
  }) : name = 'icons8-ai-48';

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? Colors.white;
    return Image.asset(
      'assets/icons/$name.png',
      width: size,
      height: size,
      color: iconColor,
      colorBlendMode: BlendMode.srcIn,
      fit: BoxFit.contain,
    );
  }
}
