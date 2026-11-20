# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

Primary user: the operator using the private 知川助手 project from an Android phone. The user wants to move from chat to real coding, builds, local files, and phone tasks without needing a separate DSH-Go installation.

## Product Purpose

知川助手 (Zhichuan Assistant) is an independent Android app for running DeepSeek Harness locally and using it as a native mobile development workspace. Success means installing one APK, setting up its bundled local runtime, connecting a model provider, then chatting, editing/building code, using plugins, and invoking Android phone capabilities from the same app.

## Positioning

A native-first Android workspace that packages the DSH engine and its Linux runtime with the app, while keeping chat, files, terminal, builds, plugins, and phone capabilities available through native app surfaces. It is not a WebView wrapper around the DSH web client.

## Operating Context

The app is used on Android phones, often for hands-on development and device workflows. The local DSH engine runs in an app-managed Ubuntu/PRoot environment and connects to the Flutter client over loopback; remote DSH hosts may remain an optional connection mode. The app needs a clear first-run path for runtime setup, model-provider configuration, and Android capabilities.

## Capabilities and Constraints

- Preserve the upstream native Flutter UI, Dart DSH client, Kotlin Android runtime/phone bridge, and plugin architecture as the functional base; replace upstream product name and restricted brand artwork with the operator-owned river mark and 知川助手 identity.
- Package the Ubuntu/PRoot, Node, DSH, and pnpm runtime in the ARM64 APK or an app-managed offline setup bundle. Add a useful local developer toolchain; the exact compiler/SDK inventory and final package size must be verified from the built artifact rather than promised in advance.
- Keep primary chat and workspace surfaces native. Optional embedded web surfaces must not become the app shell or replace the native chat UI.
- Include coding, terminal, file/workspace, build, plugin, and phone-operation workflows. Phone capabilities use Android's native permissions and services.
- Preserve the existing Android application id and release signing identity so the new APK can upgrade the existing installation, previously labelled 子川助手.
- DSH provider credentials and model access are configured by the user; the app does not claim to bundle model weights or provide offline inference.
- Preserve AGPL-3.0 source notices and applicable third-party licenses. Do not reuse upstream DSH Go marks or mascot artwork.
- The operator selected the new display brand 知川助手 (Zhichuan Assistant); keep the `zichuan-assistant` repository slug and Android application id for continuity.

## Evidence on Hand

- The operator's request specifies an independent Android application, not a thin WebView shell, with DSH, development/build tools, plugins, and phone-operation capabilities.
- The selected source base is a Flutter + Kotlin Android DSH client with a packaged Ubuntu/PRoot runtime and native phone bridge. Its upstream license and restricted-art guidance are retained in the repository notices.
- Existing private project files provide the application id and release signing identity needed for upgrade compatibility.
- No model weights, provider credentials, or verified final APK are part of the current evidence.

## Product Principles

- Native app behavior is the product; a browser view is never a substitute for the main app.
- The local engine and development environment should be self-contained and verifiable after installation.
- Move directly from an intent to an inspectable result: chat, code, build, files, and delivery stay connected.
- Phone access is part of the workspace and is surfaced through native Android capabilities.
- State what is bundled, what needs a first-run install, and what still needs provider setup.
