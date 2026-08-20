import 'package:flutter/material.dart';
import 'package:novaapp/features/chat/domain/models.dart';

class VerificationDots extends StatelessWidget {
  final VerificationLevel level;
  final double size;
  final double spacing;

  const VerificationDots({
    super.key,
    required this.level,
    this.size = 6,
    this.spacing = 2,
  });

  @override
  Widget build(BuildContext context) {
    int count;
    Color color;

    switch (level) {
      case VerificationLevel.level3:
        count = 3;
        color = Colors.green;
      case VerificationLevel.level2:
        count = 2;
        color = Colors.orange;
      case VerificationLevel.level1:
        count = 1;
        color = Colors.red;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        count,
        (i) => Container(
          width: size,
          height: size,
          margin: EdgeInsets.only(right: i < count - 1 ? spacing : 0),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
