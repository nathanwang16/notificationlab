#!/usr/bin/env python3
"""Create a dependency-free Xcode project for the two macOS probe apps."""
import pathlib, hashlib

root = pathlib.Path(__file__).resolve().parents[1]
project = root/'NotificationLab.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(name, text):
    key=uid(name);objects[key]=text;return key
files={name:add('file:'+name,f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>";}}') for name in ['Core.swift','Persistence.swift','Configuration.swift','DatabaseProbe.swift','AccessibilityProbe.swift','CaptureApp.swift','GeneratorApp.swift']}
targets=[];products=[];schemes=[]
for kind, names in [('Capture',['Core.swift','Persistence.swift','Configuration.swift','DatabaseProbe.swift','AccessibilityProbe.swift','CaptureApp.swift']),('Generator',['Core.swift','GeneratorApp.swift'])]:
    name='NotificationLab'+kind;bundle='local.notificationlab.'+kind.lower()
    display='NotificationLab '+('Sender' if kind=='Generator' else 'Capture')
    product=add('product:'+kind,f'{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR;}}');products.append(product)
    buildfiles=[add('build:'+kind+':'+file,f'{{isa = PBXBuildFile; fileRef = {files[file]};}}') for file in names]
    source=add('sources:'+kind,'{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(buildfiles)+',); runOnlyForDeploymentPostprocessing = 0;}')
    framework=add('frameworks:'+kind,'{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;}')
    configs=[]
    for configuration in ['Debug','Release']:
        settings='ALWAYS_SEARCH_USER_PATHS = NO; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_APP_SANDBOX = NO; GENERATE_INFOPLIST_FILE = YES; MARKETING_VERSION = 0.2.0; CURRENT_PROJECT_VERSION = 2; INFOPLIST_KEY_CFBundleDisplayName = "'+display+'"; INFOPLIST_KEY_NSPrincipalClass = NSApplication; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = '+bundle+'; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = macosx; SWIFT_VERSION = 5.0;'
        settings+=' SWIFT_OPTIMIZATION_LEVEL = "'+('-Onone' if configuration=='Debug' else '-O')+'";'
        configs.append(add('config:'+kind+configuration,'{isa = XCBuildConfiguration; buildSettings = {'+settings+'}; name = '+configuration+';}'))
    configlist=add('configlist:'+kind,'{isa = XCConfigurationList; buildConfigurations = ('+','.join(configs)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')
    target=add('target:'+kind,'{isa = PBXNativeTarget; buildConfigurationList = '+configlist+'; buildPhases = ('+source+','+framework+',); buildRules = (); dependencies = (); name = '+name+'; productName = '+name+'; productReference = '+product+'; productType = "com.apple.product-type.application";}')
    targets.append(target);schemes.append((name,target))
sourcegroup=add('sourcegroup','{isa = PBXGroup; children = ('+','.join(files.values())+',); path = Sources; sourceTree = "<group>";}')
productgroup=add('productgroup','{isa = PBXGroup; children = ('+','.join(products)+',); name = Products; sourceTree = "<group>";}')
main=add('main','{isa = PBXGroup; children = ('+sourcegroup+','+productgroup+',); sourceTree = "<group>";}')
configs=[add('projectconfig:'+config,'{isa = XCBuildConfiguration; buildSettings = {}; name = '+config+';}') for config in ['Debug','Release']]
configlist=add('projectconfiglist','{isa = XCConfigurationList; buildConfigurations = ('+','.join(configs)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')
proj=add('project','{isa = PBXProject; attributes = {LastUpgradeCheck = 2700;}; buildConfigurationList = '+configlist+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = '+main+'; productRefGroup = '+productgroup+'; projectDirPath = ""; projectRoot = ""; targets = ('+','.join(targets)+',);}')
text='// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text+='\n'.join(f'{key} = {value};' for key,value in objects.items())
text+='\n}; rootObject = '+proj+'; }\n'
(project/'project.pbxproj').write_text(text)
schemefolder=project/'xcshareddata/xcschemes';schemefolder.mkdir(parents=True,exist_ok=True)
for name,target in schemes:
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:NotificationLab.xcodeproj"/>'
    xml=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable><EnvironmentVariables><EnvironmentVariable key="NOTIFICATION_LAB_ROOT" value="$(SRCROOT)" isEnabled="YES"/></EnvironmentVariables></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (schemefolder/(name+'.xcscheme')).write_text(xml)
print(project)
