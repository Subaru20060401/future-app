import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import 'workplace_edit_screen.dart';

// 勤務先一覧。参考画像1準拠。タップで編集、下部のボタンで追加。
class WorkplaceListScreen extends StatelessWidget {
  const WorkplaceListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final workplaces = appState.workplaces;

    return Scaffold(
      appBar: AppBar(title: const Text('勤務先一覧')),
      body: Column(
        children: [
          Expanded(
            child: workplaces.isEmpty
                ? const Center(
                    child: Text('勤務先がまだありません。\n下のボタンから追加してください。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.separated(
                    itemCount: workplaces.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final w = workplaces[i];
                      return ListTile(
                        leading: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                              color: Color(w.colorValue), shape: BoxShape.circle),
                        ),
                        title: Text(w.name),
                        subtitle: w.genre.isNotEmpty || w.location.isNotEmpty
                            ? Text(
                                [w.genre, w.location]
                                    .where((e) => e.isNotEmpty)
                                    .join(' / '),
                                style: const TextStyle(fontSize: 12))
                            : null,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => WorkplaceEditScreen(workplace: w)),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green, foregroundColor: Colors.white),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const WorkplaceEditScreen()),
                ),
                child: const Text('勤務先を追加する', style: TextStyle(fontSize: 16)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
