// The real clipboard count behind auto-copy's "you copied something since"
// check (lib/auto_copy.dart clipboardStamp), on its own so the lookup it
// caches happens with AppKit loaded, as it is in the app.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plop/auto_copy.dart';

void main() {
  test("the Mac's pasteboard count is read, not left unknown", () async {
    DynamicLibrary.open('/System/Library/Frameworks/AppKit.framework/AppKit');
    final stamp = await clipboardStamp();
    expect(stamp, isA<int>(), reason: 'null would switch the check off');
    // It only counts copies; reading it twice gives the same number.
    expect(await clipboardStamp(), stamp);
  }, skip: !Platform.isMacOS);
}
