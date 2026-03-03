# PipePipe iOS MVP (YouTube-only, no user API key)

Минимальный MVP на Swift:
- поиск видео через YouTube InnerTube (`youtubei/v1/search`),
- список результатов + фильтры (`All / Videos / Live`) и сортировка,
- нативное воспроизведение через `KSPlayer` по прямому URL из `youtubei/v1/player`
  (embed-плеер используется только как fallback),
- очередь воспроизведения (`Play next`, `Add to queue`, `Previous/Next`),
- deeplink-парсинг YouTube URL/схем (`youtu.be`, `youtube.com/watch`, `shorts`, `embed`, `vnd.youtube`).
- действия на экране плеера: `Share`, `Open in browser`, `Add to playlist`, `Download` (MVP),
- локальная библиотека (MVP): `History` + `Local playlists` на `UserDefaults`.
- `Subscriptions` (локально) + `Feed` по подпискам (через `youtubei/v1/browse`),
- import/export подписок в JSON.
- file import/export подписок (`.json`) через системный picker,
- экран деталей плейлиста (запуск в очередь, удаление видео),
- сортировка feed (`Latest/Channel/Title`) и параллельная загрузка каналов.
- новый shell интерфейса в стиле PipePipe: главные вкладки (`Feed / Search / Subs / Library`),
- глобальный мини-плеер снизу и полноэкранный player sheet из любого раздела.
- новый root-shell c боковым меню в стиле PipePipe:
  `Subscriptions (home) / Trends / All subscriptions feed / History / Settings`,
- на `Subscriptions home`: верхняя кнопка глобального поиска, блок `Feed groups`, ниже список каналов.
- движок воспроизведения переведен на `KSPlayer` (через SPM), чтобы стабильнее работал фон/миниплеер.

## Что внутри

- `PipePipeMVP/PipePipeMVPApp.swift` — точка входа приложения
- `PipePipeMVP/Views/ContentView.swift` — экран поиска и список
- `PipePipeMVP/Views/VideoPlayerScreen.swift` — экран плеера
- `PipePipeMVP/ViewModels/SearchViewModel.swift` — состояние и бизнес-логика
- `PipePipeMVP/ViewModels/PlaybackQueueViewModel.swift` — очередь и текущий трек
- `PipePipeMVP/ViewModels/LibraryViewModel.swift` — локальная библиотека (history/playlists)
- `PipePipeMVP/ViewModels/FeedViewModel.swift` — лента по подпискам
- `PipePipeMVP/Services/VideoSearchService.swift` — HTTP API клиент
- `PipePipeMVP/Services/YouTubeDeepLinkParser.swift` — извлечение `videoId` из deeplink
- `PipePipeMVP/Models/VideoItem.swift` — модель результата
- `PipePipeMVP/Models/LibraryModels.swift` — модели history/playlist
- `PipePipeMVP/Models/SubscriptionsFileDocument.swift` — FileDocument для JSON подписок
- `PipePipeMVP/Views/LibraryView.swift` — экран библиотеки
- `PipePipeMVP/Views/SubscriptionsView.swift` — подписки + import/export
- `PipePipeMVP/Views/FeedView.swift` — feed из подписок
- `PipePipeMVP/Views/PlaylistDetailView.swift` — содержимое локального плейлиста
- `PipePipeMVP/Views/SearchTabView.swift` — поиск как отдельный основной раздел
- `PipePipeMVP/Views/SubscriptionsHomeView.swift` — первая страница подписок
- `PipePipeMVP/Views/TrendsView.swift` — страница трендов
- `PipePipeMVP/Views/HistoryView.swift` — страница истории
- `PipePipeMVP/Views/SettingsView.swift` — страница настроек
- `PipePipeMVP/Views/KSVideoSurfaceView.swift` — рендер поверхности KSPlayer в SwiftUI
- `project.yml` — конфиг генерации Xcode проекта

## Как запустить в Xcode

1. Сгенерируй проект:
   - `cd ios-mvp`
   - `xcodegen generate`
2. Открой `PipePipeMVP.xcodeproj` в Xcode.
3. Запусти на симуляторе/устройстве.

## Ограничения MVP

- User API key не нужен: сервис сам извлекает InnerTube `apiKey` и `clientVersion` из YouTube.
- Для воспроизведения используется iOS InnerTube client-ключ (внутренний, не пользовательский).
- Схема неофициальная и может ломаться при изменениях YouTube.
- Нет авторизации, оффлайна, фоновых загрузок и сложного кэша.
- Download в MVP: HLS-манифесты не сохраняются как оффлайн-видео; полноценный оффлайн требует отдельного пайплайна.
