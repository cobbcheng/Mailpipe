#!/usr/bin/env python3
"""Deterministic, dependency-free generator for the two-target M0 Xcode host project.

Both targets compile design/icon/AppIcon.icon and Mailpipe/Assets.xcassets.
AppIcon is the bundle icon; MenuBarIcon is the host menu-bar template image.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def ident(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()

def obj(label, kind, **values):
    key = ident(label)
    objects[key] = dict(isa=kind, **values)
    return key

def configs(label, settings):
    ids = []
    for name in ('Debug', 'Release'):
        flags = dict(settings)
        flags.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O',
                     SWIFT_COMPILATION_MODE='singlefile' if name == 'Debug' else 'wholemodule')
        if name == 'Debug':
            # Local Swift package products build for the destination's active arch only.
            flags['ONLY_ACTIVE_ARCH'] = 'YES'
        ids.append(obj(label + name, 'XCBuildConfiguration', name=name, buildSettings=flags))
    return obj(label + 'configs', 'XCConfigurationList', buildConfigurations=ids,
               defaultConfigurationIsVisible='0', defaultConfigurationName='Release')

app_product = obj('app-product', 'PBXFileReference', explicitFileType='wrapper.application',
                  path='Mailpipe.app', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0')
ext_product = obj('ext-product', 'PBXFileReference', explicitFileType='wrapper.app-extension',
                  path='MailpipeMailExtension.appex', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0')
package = obj('package', 'XCLocalSwiftPackageReference', relativePath='.')
lottie = obj('lottie-package', 'XCRemoteSwiftPackageReference',
             repositoryURL='https://github.com/airbnb/lottie-spm.git',
             requirement={'kind': 'exactVersion', 'version': '4.6.1'})
onboarding_art = obj('onboarding-art', 'PBXFileReference', lastKnownFileType='folder',
                     path='Mailpipe/App/OnboardingArt', sourceTree='SOURCE_ROOT')
asset_catalog = obj('asset-catalog', 'PBXFileReference', lastKnownFileType='folder.assetcatalog',
                    path='Mailpipe/Assets.xcassets', sourceTree='SOURCE_ROOT')
app_icon = obj('native-app-icon', 'PBXFileReference', lastKnownFileType='folder.icon',
               path='design/icon/AppIcon.icon', sourceTree='SOURCE_ROOT')
source_groups = []
target_ids = []
for label, source_dir, product, product_type in (
    ('MailpipeMailExtension', 'Mailpipe/MailExtension', ext_product, 'com.apple.product-type.app-extension'),
    ('Mailpipe', 'Mailpipe/App', app_product, 'com.apple.product-type.application'),
):
    source_refs, builds = [], []
    for file in sorted((ROOT / source_dir).iterdir()):
        if file.suffix not in ('.swift', '.plist', '.entitlements'):
            continue
        ref = obj(str(file.relative_to(ROOT)), 'PBXFileReference', path=str(file.relative_to(ROOT)),
                  sourceTree='SOURCE_ROOT', lastKnownFileType='sourcecode.swift' if file.suffix == '.swift' else 'text.plist.xml')
        source_refs.append(ref)
        if file.suffix == '.swift':
            builds.append(obj('build-' + str(file.relative_to(ROOT)), 'PBXBuildFile', fileRef=ref))
    if label == 'Mailpipe':
        source_refs.append(onboarding_art)
    source_groups.append(obj(label + '-files', 'PBXGroup', children=source_refs, name=label, sourceTree='<group>'))
    sources = obj(label + '-sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=builds,
                  runOnlyForDeploymentPostprocessing='0')
    package_products, framework_files = [], []
    for library in (('HarnessAdapters', 'MailpipeCore', 'MailBridge', 'MailpipeRuntime') if label == 'Mailpipe' else ('MailpipeCore',)):
        dep = obj(label + '-product-' + library, 'XCSwiftPackageProductDependency', package=package, productName=library)
        package_products.append(dep)
        framework_files.append(obj(label + '-link-' + library, 'PBXBuildFile', productRef=dep))
    if label == 'Mailpipe':
        dep = obj('lottie-product', 'XCSwiftPackageProductDependency', package=lottie, productName='Lottie')
        package_products.append(dep)
        framework_files.append(obj('lottie-link', 'PBXBuildFile', productRef=dep))
    frameworks = obj(label + '-frameworks', 'PBXFrameworksBuildPhase', buildActionMask='2147483647',
                     files=framework_files, runOnlyForDeploymentPostprocessing='0')
    asset_build = obj(label + '-asset', 'PBXBuildFile', fileRef=asset_catalog)
    icon_build = obj(label + '-native-icon', 'PBXBuildFile', fileRef=app_icon)
    resource_files = [asset_build, icon_build]
    if label == 'Mailpipe':
        resource_files.append(obj('onboarding-art-build', 'PBXBuildFile', fileRef=onboarding_art))
    resources = obj(label + '-resources', 'PBXResourcesBuildPhase', buildActionMask='2147483647',
                    files=resource_files, runOnlyForDeploymentPostprocessing='0')
    phases, dependencies = [sources, frameworks, resources], []
    if label == 'Mailpipe':
        embed = obj('embed-extension-file', 'PBXBuildFile', fileRef=ext_product, settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
        phases.append(obj('embed-extensions', 'PBXCopyFilesBuildPhase', buildActionMask='2147483647',
                          dstPath='', dstSubfolderSpec='13', files=[embed], name='Embed App Extensions', runOnlyForDeploymentPostprocessing='0'))
        proxy = obj('extension-proxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType='1',
                    remoteGlobalIDString=ident('target-MailpipeMailExtension'), remoteInfo='MailpipeMailExtension')
        dependencies.append(obj('extension-dependency', 'PBXTargetDependency', target=ident('target-MailpipeMailExtension'), targetProxy=proxy))
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.mailpipe.app' + ('.MailExtension' if label != 'Mailpipe' else ''),
                    INFOPLIST_FILE=source_dir + '/Info.plist', GENERATE_INFOPLIST_FILE='NO',
                    ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
                    SWIFT_VERSION='6.0', MACOSX_DEPLOYMENT_TARGET='13.0', CODE_SIGN_STYLE='Automatic',
                    ENABLE_HARDENED_RUNTIME='YES', MAILPIPE_APP_GROUP='$(DEVELOPMENT_TEAM).com.mailpipe.validation', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'],
                    SKIP_INSTALL='YES' if label != 'Mailpipe' else 'NO')
    if label != 'Mailpipe':
        settings.update(APPLICATION_EXTENSION_API_ONLY='YES', ENABLE_APP_SANDBOX='YES', ENABLE_DEBUG_DYLIB='NO',
                        OTHER_LDFLAGS=['$(inherited)', '-Wl,-needed_framework,MailKit'],
                        CODE_SIGN_ENTITLEMENTS=source_dir + '/MailExtension.entitlements')
    else:
        settings['ENABLE_APP_SANDBOX'] = 'NO'
        settings['CODE_SIGN_ENTITLEMENTS'] = source_dir + '/Mailpipe.entitlements'
    target_ids.append(obj('target-' + label, 'PBXNativeTarget', buildConfigurationList=configs(label, settings),
                          buildPhases=phases, buildRules=[], dependencies=dependencies, name=label, productName=label,
                          productReference=product, productType=product_type, packageProductDependencies=package_products))
products = obj('products', 'PBXGroup', children=[app_product, ext_product], name='Products', sourceTree='<group>')
main = obj('main', 'PBXGroup', children=source_groups + [asset_catalog, app_icon, products], sourceTree='<group>')
project = obj('project', 'PBXProject', attributes={'LastUpgradeCheck':'1600','BuildIndependentTargetsInParallel':'YES'},
              buildConfigurationList=configs('project', {'SDKROOT':'macosx', 'CLANG_ENABLE_MODULES':'YES', 'SWIFT_VERSION':'6.0'}),
              compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings='0', knownRegions=['en','Base'],
              mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', packageReferences=[package, lottie], targets=target_ids)

def encode(value, level=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('  '*(level+1)+json.dumps(k)+' = '+encode(v,level+1)+';\n' for k,v in value.items()) + '  '*level+'}'
    if isinstance(value, list):
        return '(' + ', '.join(encode(v,level) for v in value) + ')'
    return json.dumps(value)

path = ROOT / 'Mailpipe.xcodeproj'
path.mkdir(exist_ok=True)
(path/'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project})+'\n')
schemes = path/'xcshareddata/xcschemes'
schemes.mkdir(parents=True,exist_ok=True)
(schemes/'Mailpipe.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target-Mailpipe')}" BuildableName="Mailpipe.app" BlueprintName="Mailpipe" ReferencedContainer="container:Mailpipe.xcodeproj"/>
    </BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target-Mailpipe')}" BuildableName="Mailpipe.app" BlueprintName="Mailpipe" ReferencedContainer="container:Mailpipe.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated Mailpipe.xcodeproj')
