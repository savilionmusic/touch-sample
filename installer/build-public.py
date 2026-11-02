#!/usr/bin/env python3
"""Build the public installer without firmware, samples, kernels or driver changes."""
from pathlib import Path
import argparse, html, shutil, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
def run(*args, **kw):
    subprocess.run([str(a) for a in args], check=True, **kw)
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--font-folder',type=Path,required=True); ap.add_argument('--output',type=Path,default=ROOT/'dist/public'); args=ap.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-',dir=ROOT/'out') as temp:
        work=Path(temp); payload=work/'root'; app=payload/'Applications/Touch Sample.app'; setup=payload/'Applications/Touch Sample Setup'; setup.mkdir(parents=True)
        import os
        env=dict(os.environ,TOUCH_SAMPLE_APP_OUT=str(app))
        run('bash',ROOT/'scripts/build-app.sh',env=env)
        run('codesign','--verify','--deep','--strict',app)
        shutil.copy2(ROOT/'scripts/friend-kit/Setup.command',setup/'Setup.command')
        run('git','archive','--format=tar.gz','-o',setup/'TouchSample.tar.gz','HEAD',cwd=ROOT)
        shutil.copy2(ROOT/'README.md',setup/'README.md')
        resources=work/'resources'; resources.mkdir(); headings=work/'headings'; headings.mkdir()
        text={
        'welcome':('Touch Sample','Free from SAV LAB. Run the MPC Sample emulator with your MPC Touch. This independent project is not affiliated with Akai. No firmware, factory library or personal samples are included.'),
        'readme':('Before you start','Download the official MPC Sample 1.3.0 Updater for Mac from Akai and place its ZIP or app on your Desktop. Do not run the updater. After installing, open Applications → Touch Sample Setup → Setup.command in Terminal. Setup reads your updater locally, checks firmware version 1.3.0.12, downloads build tools and builds emulator images. Allow time for the first build. Then open Touch Sample in Applications. DisplayLink and the existing MPC Touch driver are separate prerequisites. For permissions and sample loading, read the included README.'),
        'conclusion':('Touch Sample is installed','Next: place the official Akai updater on your Desktop, then open Applications → Touch Sample Setup → Setup.command. Keep Terminal open until setup completes. Open Touch Sample after setup. Save and quit normally. This installer has not been notarized; if macOS blocks it, use Privacy & Security → Open Anyway only if you trust this download.')}
        for name,(title,body) in text.items():
            key='readme-how' if name=='readme' else name
            (resources/(name+'.html')).write_text('<html><body style="font-family:Helvetica;color:#26313a;background:#f5ebdd;padding:24px"><img src="headings/'+key+'.png" width="300" height="55" alt="'+html.escape(title)+'"><p>'+html.escape(body)+'</p><p>SAV LAB · Free software by Savilion</p><p>Alicja Hand: copyright 2026 Alicja Gajewski. Font artwork used for SAV LAB branding; no standalone font licence is granted.</p></body></html>')
        run('swiftc',ROOT/'installer/render-headings.swift','-o',work/'render')
        run(work/'render',args.font_folder,headings,resources)
        run('pkgbuild','--analyze','--root',payload,work/'components.plist')
        import plistlib
        components=plistlib.loads((work/'components.plist').read_bytes())
        for component in components: component['BundleIsRelocatable']=False
        (work/'components.plist').write_bytes(plistlib.dumps(components))
        run('pkgbuild','--root',payload,'--component-plist',work/'components.plist','--identifier','com.savilion.touchsample.public','--version','0.7.1','--install-location','/',work/'TouchSample.pkg')
        (work/'distribution.xml').write_text('''<?xml version="1.0"?><installer-gui-script minSpecVersion="2"><title>Touch Sample — SAV LAB</title><welcome file="welcome.rtfd" uti="com.apple.flat-rtfd"/><readme file="readme.rtfd" uti="com.apple.flat-rtfd"/><conclusion file="conclusion.rtfd" uti="com.apple.flat-rtfd"/><options customize="never" hostArchitectures="arm64"/><domains enable_localSystem="true"/><volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check><choices-outline><line choice="default"><line choice="com.savilion.touchsample.public"/></line></choices-outline><choice id="default"/><choice id="com.savilion.touchsample.public" visible="false"><pkg-ref id="com.savilion.touchsample.public"/></choice><pkg-ref id="com.savilion.touchsample.public" version="0.7.1">TouchSample.pkg</pkg-ref></installer-gui-script>''')
        run('productbuild','--distribution',work/'distribution.xml','--resources',resources,'--package-path',work,args.output/'Touch-Sample-0.7.1-Installer.pkg')
        shutil.copy2(ROOT/'README.md',args.output/'README.md')
        print('Built public installer:',args.output)
if __name__=='__main__': main()
