import 'package:coolapp/views/pages/expanded_flexible.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.title});
  final String title;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController nameController = TextEditingController();
  TextEditingController emailController = TextEditingController();
  bool? isChecked = false;
  bool isSwitched = false;
  double sliderValue = 0.0;
  String? dropdownValue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        centerTitle: true,
        automaticallyImplyLeading: false,
        leading: BackButton(
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: Duration(seconds: 5),
                      content: Text("Snackbar"),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                child: Text("Open Snackbar"),
              ),
              Divider(color: Colors.teal, thickness: 5.0, endIndent: 200.0),
              ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog.adaptive(
                        title: Text("Alert Title"),
                        content: Text("Alert Content"),
                        actions: [
                          FilledButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            child: Text("Close"),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Text("Show Alert"),
              ),
              SizedBox(height: 20),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                onEditingComplete: () => setState(() {}),
              ),
              SizedBox(height: 20),
              TextField(
                controller: emailController,
                decoration: InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                onEditingComplete: () => setState(() {}),
              ),
              SizedBox(height: 20),
              Checkbox.adaptive(
                tristate: true,
                value: isChecked,
                onChanged: (value) {
                  setState(() {
                    isChecked = value;
                  });
                },
              ),
              SizedBox(height: 20),
              CheckboxListTile.adaptive(
                tristate: true,
                title: Text('Subscribe to newsletter'),
                value: isChecked,
                onChanged: (value) {
                  setState(() {
                    isChecked = value;
                  });
                },
              ),
              Text(nameController.text),
              SizedBox(height: 20),
              Text(emailController.text),
              SizedBox(height: 20),
              Switch.adaptive(
                value: isSwitched,
                onChanged: (bool value) {
                  setState(() {
                    isSwitched = value;
                  });
                },
              ),
              SizedBox(height: 20),
              SwitchListTile.adaptive(
                title: Text('Enable notifications'),
                value: isSwitched,
                onChanged: (bool value) {
                  setState(() {
                    isSwitched = value;
                  });
                },
              ),
              SizedBox(height: 20),
              Slider.adaptive(
                max: 100.0,
                value: sliderValue,
                divisions: 10,
                onChanged: (double value) {
                  setState(() {
                    sliderValue = value;
                  });
                  print(sliderValue);
                },
              ),
              SizedBox(height: 20),
              InkWell(
                splashColor: Colors.teal,
                child: Container(
                  height: 50,
                  width: double.infinity,
                  color: Colors.white30,
                ),
                onTap: () {
                  print('Image tapped');
                },
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
                child: Text("Click Me"),
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => ExpandedFlexible()),
                  );
                },
                child: Text("Expanded Flexible"),
              ),
              SizedBox(height: 20),
              FilledButton(onPressed: () {}, child: Text("Click Me")),
              SizedBox(height: 20),
              OutlinedButton(onPressed: () {}, child: Text("Click Me")),
              SizedBox(height: 20),
              TextButton(onPressed: () {}, child: Text("Click Me")),
              SizedBox(height: 20),
              CloseButton(),
              SizedBox(height: 20),
              BackButton(),
              SizedBox(height: 20),
              DropdownButton(
                value: dropdownValue,
                items: [
                  DropdownMenuItem(value: 'i1', child: Text("Item 1")),
                  DropdownMenuItem(value: 'i2', child: Text("Item 2")),
                ],
                onChanged: (value) {
                  setState(() {
                    dropdownValue = value;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
