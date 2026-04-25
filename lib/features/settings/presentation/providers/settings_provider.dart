import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum BubbleStyle { standard, geometric, minimal }

class SettingsState {
  final ThemeMode themeMode;
  final BubbleStyle bubbleStyle;
  final bool readReceipts;
  final bool typingIndicator;
  final bool notificationsEnabled;
  final bool previewEnabled;
  final double fontSize;
  final bool enterSends;
  final bool autoSaveMedia;
  final bool dndEnabled;
  final String dndStartTime; // "HH:mm"
  final String dndEndTime;   // "HH:mm"

  const SettingsState({
    this.themeMode = ThemeMode.dark,
    this.bubbleStyle = BubbleStyle.standard,
    this.readReceipts = true,
    this.typingIndicator = true,
    this.notificationsEnabled = true,
    this.previewEnabled = true,
    this.fontSize = 16.0,
    this.enterSends = false,
    this.autoSaveMedia = true,
    this.dndEnabled = false,
    this.dndStartTime = "22:00",
    this.dndEndTime = "08:00",
  });

  SettingsState copyWith({
    ThemeMode? themeMode,
    BubbleStyle? bubbleStyle,
    bool? readReceipts,
    bool? typingIndicator,
    bool? notificationsEnabled,
    bool? previewEnabled,
    double? fontSize,
    bool? enterSends,
    bool? autoSaveMedia,
    bool? dndEnabled,
    String? dndStartTime,
    String? dndEndTime,
  }) {
    return SettingsState(
      themeMode: themeMode ?? this.themeMode,
      bubbleStyle: bubbleStyle ?? this.bubbleStyle,
      readReceipts: readReceipts ?? this.readReceipts,
      typingIndicator: typingIndicator ?? this.typingIndicator,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      previewEnabled: previewEnabled ?? this.previewEnabled,
      fontSize: fontSize ?? this.fontSize,
      enterSends: enterSends ?? this.enterSends,
      autoSaveMedia: autoSaveMedia ?? this.autoSaveMedia,
      dndEnabled: dndEnabled ?? this.dndEnabled,
      dndStartTime: dndStartTime ?? this.dndStartTime,
      dndEndTime: dndEndTime ?? this.dndEndTime,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier() : super(const SettingsState());

  void setThemeMode(ThemeMode mode) => state = state.copyWith(themeMode: mode);
  void setBubbleStyle(BubbleStyle style) => state = state.copyWith(bubbleStyle: style);
  void setReadReceipts(bool value) => state = state.copyWith(readReceipts: value);
  void setTypingIndicator(bool value) => state = state.copyWith(typingIndicator: value);
  void setNotificationsEnabled(bool value) => state = state.copyWith(notificationsEnabled: value);
  void setPreviewEnabled(bool value) => state = state.copyWith(previewEnabled: value);
  void setFontSize(double size) => state = state.copyWith(fontSize: size);
  void setEnterSends(bool value) => state = state.copyWith(enterSends: value);
  void setAutoSaveMedia(bool value) => state = state.copyWith(autoSaveMedia: value);
  void setDndEnabled(bool value) => state = state.copyWith(dndEnabled: value);
  void setDndRange(String start, String end) => state = state.copyWith(dndStartTime: start, dndEndTime: end);
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier();
});
