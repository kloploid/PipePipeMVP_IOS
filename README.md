# YourPipe (iOS MVP)

SwiftUI iOS-приложение для поиска и воспроизведения YouTube-видео с локальными подписками и мини-плеером.

## Features

- Поиск видео/каналов/плейлистов
- Экран воспроизведения с полноэкранным плеером
- Mini Player между вкладками
- Локальные подписки на каналы
- Лента новых видео по подпискам
- Background audio / PiP (в рамках возможностей iOS)

## Tech Stack

- SwiftUI
- AVPlayer / AVFoundation
- XcodeGen (`project.yml`)
- Неформальный YouTube extractor-слой для получения playback URL

## Requirements

- Xcode 15+
- iOS 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Run

1. Generate project:
   ```bash
   xcodegen generate
   ```
2. Open:
   - `YourPipe.xcodeproj`
3. Build and run target:
   - `YourPipe`

## Project Structure

- `YourPipe/ContentView.swift` — tabs/UI shell
- `YourPipe/PlaybackController.swift` — playback orchestration
- `YourPipe/YouTubePlaybackService.swift` — stream resolve logic
- `YourPipe/PlaybackResolver.swift` — source resolver + cache/prefetch
- `YourPipe/YouTubeSearchService.swift` — search/feed parsing
- `YourPipe/SubscriptionStore.swift` — local subscriptions persistence

## Notes

- Проект MVP-уровня и активно дорабатывается.
- Playback-стратегии зависят от изменений на стороне YouTube и могут требовать регулярных фиксов.

