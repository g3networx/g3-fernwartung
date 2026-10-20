"""Check native Swift calls before expensive macOS compilation."""
from pathlib import Path
import re
rust=Path('src/flutter.rs').read_text();header=Path('flutter/macos/Runner/g3_bridge.h').read_text();swift='\n'.join(p.read_text() for p in Path('flutter/macos/Runner').glob('*.swift'))
exports=set(re.findall(r'pub (?:unsafe )?extern "C" fn (\w+)\(',rust));calls=set(re.findall(r'\b(\w+)\s*\(',swift));required=exports&calls
assert required=={'rustdesk_core_main','handle_applicationShouldOpenUntitledFile'},required
for name in required:assert re.search(r'\b'+name+r'\s*\(void\)',header),'Missing native declaration: '+name
assert 'pub extern "C" fn rustdesk_core_main() -> bool' in rust
assert 'pub extern "C" fn handle_applicationShouldOpenUntitledFile() {' in rust
assert 'bridge_generated.h' not in Path('flutter/macos/Runner.xcodeproj/project.pbxproj').read_text()
print('Both Swift-to-Rust entry points checked against native source')
