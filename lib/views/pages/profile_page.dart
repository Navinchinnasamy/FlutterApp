import 'package:coolapp/data/constants.dart';
import 'package:coolapp/data/notifiers.dart';
import 'package:coolapp/views/pages/welcome_page.dart';
import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsGeometry.all(20.0),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50.0,
            backgroundImage: AssetImage("assets/images/bg.jpg"),
          ),
          SizedBox(height: 10.0),
          Text("User Name", style: KTextStyle.titleTealText),
          SizedBox(height: 20.0),
          ListTile(
            title: Text("Logout"),
            onTap: () {
              selectedPageNotifier.value = 0;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => WelcomePage()),
              );
            },
          ),
        ],
      ),
    );
  }
}
