import 'package:flutter/material.dart';

class ExpandedFlexible extends StatelessWidget {
  const ExpandedFlexible({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          Row(
            children: [
              Expanded(child: Container(color: Colors.teal, height: 20.0)),
              Expanded(
                flex: 2,
                child: Container(color: Colors.orange, height: 20.0),
              ),
              Flexible(
                child: Container(
                  color: Colors.blue,
                  height: 20.0,
                  child: Text("This is the Flexible Container"),
                ),
              ),
            ],
          ),
          Divider(),
          Row(
            children: [
              Flexible(
                flex: 4,
                child: Container(
                  color: Colors.blue,
                  height: 20.0,
                  child: Text("This is the Flexible Container"),
                ),
              ),
              Expanded(child: Container(color: Colors.teal, height: 20.0)),
              Expanded(
                flex: 2,
                child: Container(color: Colors.orange, height: 20.0),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
