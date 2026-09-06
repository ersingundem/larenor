import 'package:flutter/cupertino.dart';

class HomePeopleScreen extends StatelessWidget {
  const HomePeopleScreen({super.key,this.adminManagement=false,this.gateCurrent,this.onExit});
  final bool adminManagement;
  final bool Function()? gateCurrent;
  final VoidCallback? onExit;
  @override Widget build(BuildContext context)=>const SizedBox.shrink();
}
