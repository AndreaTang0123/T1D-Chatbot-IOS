"""Generate a dependency-free Xcode project, including any exported model resources."""
from pathlib import Path
import hashlib
ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'ios'
PROJECT = IOS / 'JoeMobile.xcodeproj'
PROJECT.mkdir(exist_ok=True)
def ident(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
objects = {}
def add(key, value): objects[ident(key)] = value; return ident(key)
def q(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
sources = sorted((IOS / 'JoeMobile').rglob('*.swift'))
resources = sorted(p for p in (IOS/'JoeMobile/Resources').iterdir() if p.suffix in ('.json', '.mlpackage', '.mlmodel', '.xcassets'))
refs=[]; builds=[]; resource_builds=[]
for p in sources + resources:
    path=p.relative_to(IOS).as_posix()
    kind = 'sourcecode.swift' if p.suffix == '.swift' else {'json':'text.json', 'mlpackage':'folder.mlpackage', 'mlmodel':'file.mlmodel', 'xcassets':'folder.assetcatalog'}[p.suffix[1:]]
    ref=add(path, f'{{isa = PBXFileReference; lastKnownFileType = {q(kind)}; path = {q(path)}; sourceTree = "<group>"; }}')
    build=add(path+'build', f'{{isa = PBXBuildFile; fileRef = {ref}; }}')
    refs.append(ref)
    (builds if p.suffix == '.swift' else resource_builds).append(build)
product=add('product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = JoeMobile.app; sourceTree = BUILT_PRODUCTS_DIR; }')
package=add('package','{isa = XCLocalSwiftPackageReference; relativePath = ..; }')
package_product=add('package_product',f'{{isa = XCSwiftPackageProductDependency; package = {package}; productName = JoeCore; }}')
package_build=add('package_build', f'{{isa = PBXBuildFile; productRef = {package_product}; }}')
def phase(key,isa,files): return add(key, f'{{isa = {isa}; buildActionMask = 2147483647; files = ({",".join(files)}); runOnlyForDeploymentPostprocessing = 0; }}')
src=phase('sources','PBXSourcesBuildPhase',builds)
res=phase('resources','PBXResourcesBuildPhase',resource_builds)
framework=phase('frameworks','PBXFrameworksBuildPhase',[package_build])
group=add('main_group', f'{{isa = PBXGroup; children = ({",".join(refs+[product])}); sourceTree = "<group>"; }}')
proj_configs=[]; target_configs=[]
for mode in ['Debug','Release']:
    proj_configs.append(add('proj'+mode, '{isa = XCBuildConfiguration; name = '+mode+'; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 26.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }; }'))
    settings={'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'org.joe.mobile', 'INFOPLIST_FILE':'JoeMobile/Resources/Info.plist', 'CODE_SIGN_ENTITLEMENTS':'JoeMobile/Resources/JoeMobile.entitlements', 'CODE_SIGN_STYLE':'Automatic', 'TARGETED_DEVICE_FAMILY':'1', 'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'targeted', 'GENERATE_INFOPLIST_FILE':'NO', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'0.1.0', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
    target_configs.append(add('target'+mode, '{isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+''.join(k+' = '+q(v)+'; ' for k,v in settings.items())+'}; }'))
def configs(key,items): return add(key, f'{{isa = XCConfigurationList; buildConfigurations = ({",".join(items)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
pc=configs('projconfigs',proj_configs); tc=configs('targetconfigs',target_configs)
target=add('target', f'{{isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({src},{framework},{res}); buildRules = (); dependencies = (); name = JoeMobile; packageProductDependencies = ({package_product}); productName = JoeMobile; productReference = {product}; productType = "com.apple.product-type.application"; }}')
project=add('project', f'{{isa = PBXProject; attributes = {{LastUpgradeCheck = 2600; TargetAttributes = {{{target} = {{CreatedOnToolsVersion = 26.0; SystemCapabilities = {{com.apple.HealthKit = {{enabled = 1; }}; com.apple.BackgroundModes = {{enabled = 1; }}; }}; }}; }}; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {group}; packageReferences = ({package}); projectDirPath = ""; projectRoot = ""; targets = ({target}); }}')
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
schemes=PROJECT/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
(schemes/'JoeMobile.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="JoeMobile.app" BlueprintName="JoeMobile" ReferencedContainer="container:JoeMobile.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="JoeMobile.app" BlueprintName="JoeMobile" ReferencedContainer="container:JoeMobile.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(PROJECT)
