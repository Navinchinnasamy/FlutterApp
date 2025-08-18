import 'package:coolapp/data/constants.dart';
import 'package:coolapp/views/pages/course_page.dart';
import 'package:coolapp/widgets/container_widget.dart';
import 'package:coolapp/widgets/hero_widget.dart';
import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    List<String> list = [
      KValue.basicLayoutTitle1,
      KValue.cleanUI,
      KValue.fixBugs,
      KValue.keyConcepts,
    ];

    return Padding(
      padding: EdgeInsetsGeometry.symmetric(horizontal: 20.0),
      child: SingleChildScrollView(
        child: Column(
          children: [
            HeroWidget(title: "Home Page", nextPage: CoursePage()),
            ...List.generate(list.length, (index) {
              return ContainerWidget(
                title: list.elementAt(index),
                description: "The description of Card",
              );
            }),
          ],
        ),
      ),
    );
  }
}
