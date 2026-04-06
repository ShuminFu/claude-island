#!/usr/bin/env python3
"""Add a ClaudeIslandTests test target to the Xcode project."""

import re
import sys

PBXPROJ = "ClaudeIsland.xcodeproj/project.pbxproj"

# Unique IDs for the new objects (24 hex chars each)
ID_TEST_BUNDLE_REF   = "AABBCC010000000000000001"
ID_TEST_SYNC_GROUP   = "AABBCC020000000000000002"
ID_TEST_FW_PHASE     = "AABBCC030000000000000003"
ID_TEST_SRC_PHASE    = "AABBCC040000000000000004"
ID_TEST_TARGET       = "AABBCC050000000000000005"
ID_TARGET_DEP        = "AABBCC060000000000000006"
ID_CONTAINER_PROXY   = "AABBCC070000000000000007"
ID_TEST_CFG_DEBUG    = "AABBCC080000000000000008"
ID_TEST_CFG_RELEASE  = "AABBCC090000000000000009"
ID_TEST_CFG_LIST     = "AABBCC0A000000000000000A"

# Existing IDs from the project
ID_APP_TARGET        = "FD33FD5C2EDF32D7002A6548"
ID_PROJECT           = "FD33FD552EDF32D7002A6548"
ID_MAIN_GROUP        = "FD33FD542EDF32D7002A6548"
ID_PRODUCTS_GROUP    = "FD33FD5E2EDF32D7002A6548"

def main():
    with open(PBXPROJ, "r") as f:
        content = f.read()

    # 1. Add PBXContainerItemProxy section (before PBXFileReference)
    container_proxy = f"""
/* Begin PBXContainerItemProxy section */
\t\t{ID_CONTAINER_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {ID_PROJECT} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {ID_APP_TARGET};
\t\t\tremoteInfo = ClaudeIsland;
\t\t}};
/* End PBXContainerItemProxy section */

"""
    content = content.replace(
        "/* Begin PBXFileReference section */",
        container_proxy + "/* Begin PBXFileReference section */"
    )

    # 2. Add test bundle to PBXFileReference section
    test_ref = f'\t\t{ID_TEST_BUNDLE_REF} /* ClaudeIslandTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ClaudeIslandTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
    content = content.replace(
        "/* End PBXFileReference section */",
        test_ref + "/* End PBXFileReference section */"
    )

    # 3. Add tests PBXFileSystemSynchronizedRootGroup
    test_sync = f"""\t\t{ID_TEST_SYNC_GROUP} /* tests */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = tests;
\t\t\tsourceTree = "<group>";
\t\t}};
"""
    content = content.replace(
        "/* End PBXFileSystemSynchronizedRootGroup section */",
        test_sync + "/* End PBXFileSystemSynchronizedRootGroup section */"
    )

    # 4. Add test PBXFrameworksBuildPhase
    test_fw = f"""\t\t{ID_TEST_FW_PHASE} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
    content = content.replace(
        "/* End PBXFrameworksBuildPhase section */",
        test_fw + "/* End PBXFrameworksBuildPhase section */"
    )

    # 5. Add tests group to main group children AND test bundle to Products group
    # Main group: add tests sync group
    content = content.replace(
        f"\t\t\t\t{ID_PRODUCTS_GROUP} /* Products */,",
        f"\t\t\t\t{ID_TEST_SYNC_GROUP} /* tests */,\n\t\t\t\t{ID_PRODUCTS_GROUP} /* Products */,"
    )
    # Products group: add test bundle
    content = content.replace(
        '\t\t\t\tFD33FD5D2EDF32D7002A6548 /* Claude Island.app */,',
        f'\t\t\t\tFD33FD5D2EDF32D7002A6548 /* Claude Island.app */,\n\t\t\t\t{ID_TEST_BUNDLE_REF} /* ClaudeIslandTests.xctest */,'
    )

    # 6. Add PBXNativeTarget for tests
    test_target = f"""\t\t{ID_TEST_TARGET} /* ClaudeIslandTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ID_TEST_CFG_LIST} /* Build configuration list for PBXNativeTarget "ClaudeIslandTests" */;
\t\t\tbuildPhases = (
\t\t\t\t{ID_TEST_SRC_PHASE} /* Sources */,
\t\t\t\t{ID_TEST_FW_PHASE} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{ID_TARGET_DEP} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{ID_TEST_SYNC_GROUP} /* tests */,
\t\t\t);
\t\t\tname = ClaudeIslandTests;
\t\t\tproductName = ClaudeIslandTests;
\t\t\tproductReference = {ID_TEST_BUNDLE_REF} /* ClaudeIslandTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
"""
    content = content.replace(
        "/* End PBXNativeTarget section */",
        test_target + "/* End PBXNativeTarget section */"
    )

    # 7. Add to PBXProject targets list and TargetAttributes
    content = content.replace(
        f"\t\t\t\t{ID_APP_TARGET} /* ClaudeIsland */,\n\t\t\t);\n\t\t}};\n/* End PBXProject section */",
        f"\t\t\t\t{ID_APP_TARGET} /* ClaudeIsland */,\n\t\t\t\t{ID_TEST_TARGET} /* ClaudeIslandTests */,\n\t\t\t);\n\t\t}};\n/* End PBXProject section */"
    )
    content = content.replace(
        f"""\t\t\t\t\t{ID_APP_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.1.1;
\t\t\t\t\t}};""",
        f"""\t\t\t\t\t{ID_APP_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.1.1;
\t\t\t\t\t}};
\t\t\t\t\t{ID_TEST_TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.1.1;
\t\t\t\t\t\tTestTargetID = {ID_APP_TARGET};
\t\t\t\t\t}};"""
    )

    # 8. Add test PBXSourcesBuildPhase
    test_src = f"""\t\t{ID_TEST_SRC_PHASE} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
    content = content.replace(
        "/* End PBXSourcesBuildPhase section */",
        test_src + "/* End PBXSourcesBuildPhase section */"
    )

    # 9. Add PBXTargetDependency section (before XCBuildConfiguration)
    target_dep = f"""
/* Begin PBXTargetDependency section */
\t\t{ID_TARGET_DEP} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {ID_APP_TARGET} /* ClaudeIsland */;
\t\t\ttargetProxy = {ID_CONTAINER_PROXY} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

"""
    content = content.replace(
        "/* Begin XCBuildConfiguration section */",
        target_dep + "/* Begin XCBuildConfiguration section */"
    )

    # 10. Add test XCBuildConfigurations
    test_configs = f"""\t\t{ID_TEST_CFG_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 15.6;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.engels74.ClaudeIslandTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_APPROACHABLE_CONCURRENCY = YES;
\t\t\t\tSWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;
\t\t\t\tSWIFT_VERSION = 6;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Claude Island.app/Contents/MacOS/Claude Island";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{ID_TEST_CFG_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 15.6;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.engels74.ClaudeIslandTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_APPROACHABLE_CONCURRENCY = YES;
\t\t\t\tSWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;
\t\t\t\tSWIFT_VERSION = 6;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Claude Island.app/Contents/MacOS/Claude Island";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""
    content = content.replace(
        "/* End XCBuildConfiguration section */",
        test_configs + "/* End XCBuildConfiguration section */"
    )

    # 11. Add test XCConfigurationList
    test_cfg_list = f"""\t\t{ID_TEST_CFG_LIST} /* Build configuration list for PBXNativeTarget "ClaudeIslandTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ID_TEST_CFG_DEBUG} /* Debug */,
\t\t\t\t{ID_TEST_CFG_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
"""
    content = content.replace(
        "/* End XCConfigurationList section */",
        test_cfg_list + "/* End XCConfigurationList section */"
    )

    with open(PBXPROJ, "w") as f:
        f.write(content)

    print("Successfully added ClaudeIslandTests target to project.")

if __name__ == "__main__":
    main()
