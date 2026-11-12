"""Keep old MSI versions; g3.40+ uses 1.release.patch for Windows upgrades."""
import re

def windows_version(version):
    match=re.fullmatch(r'1\.5\.(?:0|3)-g3\.(\d{1,3})(?:\.(\d{1,5}))?',version)
    if not match:raise ValueError('Invalid package version')
    release=int(match[1]);patch=int(match[2] or 0)
    if match[2] is None and release<40:return f'1.5.{release}'
    if not 40<=release<=255 or patch>65535:raise ValueError('Unsupported Windows package version')
    return f'1.{release}.{patch}'

if __name__=='__main__':
    assert windows_version('1.5.0-g3.34')=='1.5.34'
    assert windows_version('1.5.0-g3.40')=='1.40.0'
    assert windows_version('1.5.0-g3.40.1')=='1.40.1'
    assert windows_version('1.5.0-g3.41')=='1.41.0'
    assert windows_version('1.5.3-g3.62.20058')=='1.62.20058'
    for invalid in ('1.5.0-g3.40.1-evil','1.5.0-g3.34.1','1.5.0-g3.256.1','1.5.0-g3.40.65536'):
        try:windows_version(invalid)
        except ValueError:pass
        else:raise AssertionError('Accepted invalid package version')
    print('Windows version mapping checks passed')
