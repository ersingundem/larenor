import 'package:flutter/cupertino.dart';
import '../domain/home_person_models.dart';

class HomePersonGrantsScreen extends StatelessWidget {
  const HomePersonGrantsScreen({super.key,required this.target,required this.gateCurrent});
  final HomePersonRecord target;
  final bool Function() gateCurrent;
  @override Widget build(BuildContext context)=>const SizedBox.shrink();
}
