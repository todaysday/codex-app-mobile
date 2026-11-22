# Codex Mobile + ChatGPT Web — Project Handoff

**Версия документа:** 0.1  
**Дата:** 2026-10-26  
**Статус:** техническое ТЗ / handoff для coding agent  
**Целевая платформа:** iPhone, iOS 18.7.8+ (первый тест — iOS 18.7.8)  
**Приоритет:** Codex — основной продукт; ChatGPT Web — дополнительный режим.

---

## 1. Цель проекта

Создать **одно нативное iOS-приложение** на Swift/SwiftUI, объединив:

1. **CodexAppMobile** — основа приложения и главный пользовательский интерфейс. Клиент подключается к уже работающему `codex app-server` на VPS, показывает проекты, сессии, модели и взаимодействия с агентом.
2. **ChatGPT-WebView** — источник реализации вспомогательного экрана `ChatGPT Web` на базе `WKWebView`, который открывает `https://chatgpt.com` и позволяет использовать возможности веб-аккаунта ChatGPT, включая Pro, **если авторизация и веб-функции поддерживаются на устройстве**.

**Ключевое требование: учётные записи и сессии Codex и ChatGPT Web независимы.** Они могут принадлежать разным OpenAI-аккаунтам. Вход, выход, смена аккаунта и очистка данных в одном модуле **не должны** менять авторизацию другого модуля и официального ChatGPT из App Store.

Это **не клон официального ChatGPT IPA**, не обёртка вокруг него и не запуск через LiveContainer. Результат — самостоятельное iOS-приложение с собственной иконкой и Bundle ID.

### Зафиксированные решения

- Основной код: `https://github.com/shuto-S/codex-app-mobile`.
- Донор реализации веб-экрана: `https://github.com/Akuma1tko/ChatGPT-WebView`.
- Базовый UI и существующую Codex-функциональность **сохранить**, а не переписывать.
- Рабочий `codex app-server` на VPS **уже существует**: не создавать второй экземпляр без технической необходимости.
- Codex — экран по умолчанию. ChatGPT Web доступен через отдельную вкладку и не перекрывает рабочий процесс Codex.
- Сборка: GitHub Actions на hosted macOS runner, **без собственного Mac**.
- Артефакт: unsigned `.ipa`, пригодный для последующей подписи инструментами пользователя.
- Установка: нативное приложение **через SideStore** (встроенный в LiveContainer+SideStore) либо запасным способом через Impactor. Сам клиент **не импортировать в LiveContainer**.
- Приложение рассчитано на личное использование; не закладывать App Store-публикацию в MVP.

## 2. Исходные проекты и условия использования

| Компонент | Репозиторий | Назначение | Лицензия |
|---|---|---|---|
| CodexAppMobile | https://github.com/shuto-S/codex-app-mobile | SwiftUI; прямой WebSocket к `codex app-server`, SSH fallback; проекты, threads, модель, reasoning, approvals | MIT |
| ChatGPT-WebView | https://github.com/Akuma1tko/ChatGPT-WebView | Swift + WKWebView; пример браузерной обёртки с сохранением входа и микрофоном | MIT |
| Codex App Server | https://developers.openai.com/codex/app-server | Официальный протокол сервера Codex и методы управления сессиями | Проверять актуальную документацию |
| LiveContainer + SideStore | https://livecontainer.github.io/ru/docs/installation/lc_sidestore | Только способ установки/продления подписи, **не среда запуска нашего приложения** | — |
| Impactor | https://github.com/claration/impactor | Запасная первичная установка и подпись | — |

**Юридическая/инженерная задача:** сохранить MIT-уведомления об авторстве обеих баз и учесть `THIRD_PARTY_LICENSES.md` / NOTICE зависимостей. Из ChatGPT-WebView переносить **только необходимый исходный код/идеи**, не встраивать чужой готовый `.ipa` и не переносить неподтверждённые хаки User-Agent вслепую.

### Исходное состояние CodexAppMobile (подтверждено README)

- `CodexAppMobile/App/` — lifecycle и корневой wiring.
- `CodexAppMobile/Features/Orchestration/` — Codex App Server, UI и доменная логика.
- `CodexAppMobile/Features/Terminal/` — SSH-терминал.
- `CodexAppMobileTests/` — тесты.
- Поддержка iOS 18.0+, WebSocket app-server, thread create/resume/fork/archive, модель, reasoning, collaboration mode, approvals, SSH fallback.
- Host credentials хранятся в Keychain, метаданные — в UserDefaults.
- **В README указан `NSAllowsArbitraryLoads=true`** — перед реальным использованием проверить транспортную безопасность; предпочтительно WSS/TLS или приватный сетевой туннель.

### Исходное состояние ChatGPT-WebView

- Минимальная реализация, ориентированная на iOS 15–16: `ViewController.swift`, `AppDelegate/`, `Info.plist`.
- Заявлены persistent login, микрофон, тёмная тема.
- **Нельзя считать доказанной** совместимость входа Google/Apple/passkey и ChatGPT Pro на iOS 18.7.8: это предмет первого пользовательского теста.

## 3. Концепция пользовательского интерфейса

Основная навигация:

```text
┌─────────────────────────────────┐
│ Codex Mobile                    │
│                                 │
│ [ Codex ] [ ChatGPT ] [ Settings ]
│                                 │
│ Codex (default):                │
│  Hosts → Projects → Threads     │
│  Model / Reasoning / Approvals  │
│                                 │
│ ChatGPT (secondary):            │
│  chatgpt.com in WKWebView       │
│  independent web session        │
└─────────────────────────────────┘
```

**MVP UI:**

- Вкладка **Codex**: существующие экраны оригинального CodexAppMobile; открывается при обычном запуске.
- Вкладка **ChatGPT**: встроенный веб-экран, индикатор загрузки, Back/Forward (по необходимости), Reload, Open in Safari как fallback, «Sign out / Clear ChatGPT web data» с подтверждением.
- Вкладка **Settings**: подключение к VPS/серверу, параметры Codex, диагностика WebView, версия сборки.
- Переключение вкладок **не создаёт новый WebView каждый раз** и не уничтожает текущую сессию Codex. Сохранять экран/состояние браузера через долгоживущую модель/координатор, а не пересоздавать `WKWebView` при каждом SwiftUI rerender.
- Никаких автоматических действий с аккаунтами ChatGPT/Codex при переключении вкладок.

## 4. Независимая авторизация: обязательный дизайн

### 4.1 Codex — авторизация на VPS

- Удалённый `codex app-server` использует авторизацию, уже настроенную в своём окружении на VPS.
- iOS-приложение подключается к удалённому App Server через защищённый транспорт. **Не запрашивать в iOS-приложении логин/пароль второго OpenAI-аккаунта для Codex**, если для этого нет отдельного обоснованного сервера/API.
- Пароли SSH, bearer/access токены и иные секреты подключения хранить в **iOS Keychain**; не класть в `UserDefaults`, логи или GitHub Actions artifacts.
- Если нужна изоляция от других аккаунтов Codex на том же VPS, использовать отдельный `CODEX_HOME` **на стороне VPS** и документировать, к какому процессу app-server подключается клиент. В текущей задаче действующий app-server не заменять.

### 4.2 ChatGPT Web — собственная веб-сессия на iPhone

- `WKWebView` открывает официальный `https://chatgpt.com`.
- Использовать постоянное хранилище `WKWebsiteDataStore.default()` для cookie, localStorage и сайта. **Не использовать `nonPersistent()`** для обычного режима: иначе вход теряется при завершении процесса.
- WebView внутри приложения хранит собственные данные сайта, не использует credentials/cookies Codex App Server и не должен вмешиваться в приложение ChatGPT из App Store.
- Не передавать cookies, access/refresh tokens, пароли и OAuth-коды между ChatGPT WebView и Codex.
- Не внедрять JavaScript для чтения токенов, автоматического логина, обхода CAPTCHA/Cloudflare или имитации официального приложения.
- `Clear ChatGPT web data` очищает **только данные нужного WebView/доменов**, а не Keychain Codex и не все данные приложения. Проверить фактическое поведение API очистки до релиза; для одного WebView с выделенным хранилищем предпочтительна изоляция по data store, если её поддерживает deployment target.
- Сторонние tracking/analytics SDK не добавлять.

### 4.3 Точки риска OAuth

Google ограничивает авторизацию OAuth внутри embedded `WKWebView`. Поэтому возможны ошибки при входе через Google, даже если email-вход работает.

**Порядок экспериментов:**

1. Открыть ChatGPT WebView, пройти обычную авторизацию и проверить доступ к истории.
2. Проверить **реальный метод входа нужного аккаунта** (Google/Apple/email/passkey), а не подменять его другим.
3. Если вход блокируется, показать понятное сообщение и кнопку открытия сайта в системном браузере; проверить `SFSafariViewController`/`ASWebAuthenticationSession` только как отдельный proof-of-concept. **Не предполагать**, что cookies из системного браузера автоматически попадут в `WKWebView`.
4. Если вход в WebView не заработает, **MVP с функцией ChatGPT Web не считать завершённым**. Не делать фиктивный успешный статус; Codex-клиент должен оставаться полностью работоспособным.

В отличие от экспериментов с переподписанным оригинальным ChatGPT IPA, здесь **нет необходимости запускать нативное приложение OpenAI**, его entitlements или App Attest.

## 5. Техническая архитектура

```text
┌───────────────────────────────────────────────┐
│ Codex Mobile (SwiftUI, independent bundle ID) │
├────────────────────────┬──────────────────────┤
│ Codex module           │ ChatGPT Web module   │
│ Original Orchestration │ WKWebView            │
│ + Terminal             │ Persistent cookies   │
│ Models/threads/agents  │ Official chatgpt.com │
├────────────────────────┴──────────────────────┤
│ App Navigation / Settings / shared UI shell   │
└──────────────┬────────────────┬───────────────┘
               │                │
      WSS / protected       HTTPS on-device
      connection            web session
               │                │
       ┌───────▼──────┐  ┌──────▼────────┐
       │ Existing VPS │  │ ChatGPT Web   │
       │ Codex Server │  │ (account B)   │
       │ (account A)  │  └───────────────┘
       └──────────────┘
```

**Предлагаемая структура новых файлов** (адаптировать к фактической схеме Xcode target):

```text
CodexAppMobile/
  App/
    AppRootView.swift                  # Tab shell, Codex first
  Features/
    Orchestration/                    # existing; do not regress
    Terminal/                         # existing; do not regress
    ChatGPTWeb/
      ChatGPTWebView.swift             # UIViewRepresentable bridge
      ChatGPTWebViewModel.swift        # persistent WKWebView ownership
      ChatGPTNavigationDelegate.swift # navigation/auth errors
      ChatGPTWebSettingsView.swift     # reload/clear data/debug
  Resources/
    Attribution/                      # donor source notices/licenses
CodexAppMobileTests/
  ChatGPTWebTests.swift
.github/workflows/
  ios-unsigned-ipa.yml
```

Интегрировать минимальными изолированными изменениями. **Не перетаскивать второй `AppDelegate` или отдельную точку входа донорского приложения**; перенести лишь функциональность контроллера во `UIViewRepresentable` или подходящий SwiftUI adapter.

## 6. Подключение к существующему Codex App Server

- Параметры VPS/порт **не зашивать** в исходники, читать из настроек Hosts.
- Сначала проверить адрес и транспорт действующего `codex app-server` (он уже работает). **Не создавать дубликат** процесса и не менять существующие сессии.
- Совместимость с прямым WebSocket `codex app-server` сохранить.
- Не публиковать незащищённый WebSocket в интернет.
- Возможные безопасные варианты: приватный Tailnet либо WSS через аутентифицированный прокси. Для Cloudflare Access проверить, что приложение умеет предъявлять Service Token при WebSocket handshake, иначе реализовать поддержку заголовков до использования.
- **Практический конфликт iOS:** LocalDevVPN используется для SideStore, а Tailscale также занимает VPN-конфигурацию. Не предполагать, что обе VPN одновременно активны. Либо переключать их при refresh, либо использовать защищённый WSS, которому VPN на телефоне не нужен.

### Существующие функции — не ломать

- Hosts / Projects / workspace CWD.
- История threads, создание и resume, fork/archive.
- Model picker, reasoning effort, collaboration mode.
- Промпты, streaming, approvals и user-input requests.
- SSH Terminal fallback.
- Secure Keychain credentials и локальные уведомления.

## 7. Codex-план развития (не блокировать MVP)

Приоритет после успешной интеграции WebView:

**P1 — управление текущей работой:**

- Goal Mode: `thread/goal/get`, `thread/goal/set`, `thread/goal/clear`; показать objective/status/tokenBudget/tokensUsed/timeUsedSeconds; подписаться на `thread/goal/updated` / `thread/goal/cleared`. Не выдумывать свойства, которых нет в API.
- Субагенты: дерево родительских/дочерних threads, просмотр дочерних сообщений, статусы, переход по сессиям; учесть экспериментальные фильтры `parentThreadId` / `ancestorThreadId` и opt-in experimental API при необходимости.
- Корректное подключение к **существующим** сессиям, включая те, что открыты через CLI/десктоп. Одновременное управление активной сессией проверять отдельно.

**P2 — расширенный UI:**

- Git diff, файлы, worktrees, расширенная история.
- Уведомления о запросах подтверждения, завершении задач и изменении Goal — с учётом ограничений фоновой работы iOS.
- Улучшенное отображение действий субагентов и логов.

**Не делать без прямого решения пользователя:** кастомный backend ChatGPT Pro, интеграцию ChatGPT с API-ключом вместо веб-вкладки, объединение аккаунтов, автоматический обмен контентом между Codex и ChatGPT.

## 8. GitHub Actions: сборка IPA без Mac

Требования:

1. Public fork CodexAppMobile (или private, учитывая квоту GitHub Actions).
2. Hosted `macos-15`/`macos-latest` runner с Xcode; зафиксировать совместимую Xcode-версию по результатам первой сборки.
3. `xcodebuild ... -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
4. Создать каталог `Payload/`, положить в него скомпилированный `CodexAppMobile.app`, заархивировать `Payload/` в `.ipa`.
5. Загрузить unsigned IPA как GitHub Actions artifact.
6. Автоматический запуск на `push` в основную ветку и ручной `workflow_dispatch`.
7. Проверка компиляции и тестов, доступных без пользовательской подписи; настоящий вход в ChatGPT проверять только на устройстве.

**Важное:** до внедрения готового workflow coding agent обязан посмотреть фактическую схему (`xcodebuild -list`), target settings, signing и build products. Не подставлять вымышленные имена схемы или пути к `.app`.

Не класть Apple ID, сертификаты, приватные ключи и cookies в публичный репозиторий или artifacts. Установочную подпись выполнять **на устройстве через SideStore** либо локально через Impactor; CI выпускает именно unsigned артефакт.

## 9. Установка и управление подписью

**Основной путь:**

1. Скачиваем unsigned IPA из GitHub Actions в «Файлы» iPhone.
2. Открываем **встроенный SideStore → My Apps → `+`** (через уже установленный LiveContainer+SideStore).
3. Устанавливаем IPA **как самостоятельное приложение iOS** — оно появляется на домашнем экране и не запускается внутри LiveContainer.
4. Для переподписи используем SideStore и LocalDevVPN. С бесплатным Apple ID срок действия установки обычно 7 дней.
5. Проверяем **реальное** успешное продление подписи на устройстве.

**Fallback:** Impactor на компьютере. Не смешивать способы установки/refresh без проверки Bundle ID, Apple Team и сохранения данных.

**Обязательный Bundle ID:** новый, уникальный, не `com.openai.chat` и не идентификатор App Store ChatGPT. Например, `dev.personal.codexmobile` — пример, фактический ID назначить перед сборкой.

На устройстве сохраняем официальный ChatGPT из App Store отдельно. В новой сборке Codex Mobile также есть дополнительная ChatGPT Web-вкладка; это **три разные независимые поверхности**: App Store ChatGPT, Codex App Server, ChatGPT Web внутри Codex Mobile.

## 10. План работ для coding agent

### Этап 0 — инспекция двух репозиториев

- Склонировать оба репозитория, зафиксировать commit SHAs и лицензии.
- Проверить актуальную SwiftUI-архитектуру, Xcode scheme/deployment target и существующие тесты.
- Найти минимальный участок `ChatGPT-WebView`, пригодный для портирования (не копировать непроверенные plist-значения и IPA).
- Проверить ограничения WebView для авторизации и файлов/микрофона на iOS 18.7.8.
- Подготовить краткий отчёт о технических рисках и местах изменений.

### Этап 1 — интеграция Codex + ChatGPT Web

- Fork/branch CodexAppMobile, его структура остаётся базой.
- Добавить новую вкладку и SwiftUI-мост к долгоживущему `WKWebView`.
- Реализовать persistent storage и отдельную кнопку очистки данных ChatGPT Web.
- Сделать защиту от потери состояния при переключении вкладок.
- Сохранить все существующие Codex функции; покрыть navigation базовыми тестами.

### Этап 2 — авторизация и связь

- Проверить, что старый Codex Host и чаты работают как раньше.
- Проверить независимый веб-вход ChatGPT на **настоящем iPhone** и повторный запуск приложения.
- Проверить, что logout ChatGPT Web не влияет на Codex / официальное приложение ChatGPT.
- Проверить, что смена Codex сервера/учётки не влияет на ChatGPT Web.
- Если Google OAuth не работает в `WKWebView`, провести отдельный тест fallback. Не писать «готово» без успешного реального входа.

### Этап 3 — CI и выпуск

- Добавить GitHub Actions workflow unsigned IPA.
- Сделать чистую сборку с macOS runner.
- Проверить установку через SideStore **вне LiveContainer**.
- Сделать smoke tests после установки и после refresh подписи.
- Задокументировать установку, обновление и восстановление из IPA.

### Этап 4 — Codex-функции (отдельные задачи)

- Сначала Goal Mode.
- Затем дерево субагентов и просмотр их сообщений.
- После этого — Git/worktree/diff и улучшения approvals.

## 11. Definition of Done для MVP

- [ ] Приложение компилируется на GitHub Actions macOS и выдаёт downloadable unsigned IPA.
- [ ] IPA устанавливается через SideStore как **отдельное** приложение iOS, с собственной иконкой.
- [ ] Codex подключается к **существующему** app-server на VPS без запуска второго экземпляра.
- [ ] Можно открыть проекты, существующую сессию, продолжить чат, выбрать модель и reasoning, ответить на approval.
- [ ] Вкладка ChatGPT загружает `https://chatgpt.com`.
- [ ] Во вкладке ChatGPT действительно проходит вход во **второй аккаунт** на целевом iPhone (включая нужный пользователю способ входа).
- [ ] В ChatGPT Web доступна нужная веб-функциональность аккаунта, включая Pro-режим, если он положен этому аккаунту.
- [ ] Сессия ChatGPT Web сохраняется после перехода в Codex, закрытия и повторного открытия приложения.
- [ ] Выход из ChatGPT Web не разлогинивает Codex, Safari или официальный ChatGPT.
- [ ] Отключение Codex App Server не ломает вкладку ChatGPT Web и наоборот.
- [ ] Отсутствуют секреты в Git, логи не содержат cookies/tokens; TLS/авторизация к VPS проверены.
- [ ] Повторное обновление подписи SideStore протестировано без потери локальных данных.
- [ ] MIT notices и третьесторонние атрибуции включены.

## 12. Открытые технические вопросы / риски

1. **ChatGPT OAuth внутри WKWebView:** может быть заблокирован Google/сайтом. Полное выполнение DoD зависит от реального теста; успешность не обещать заранее.
2. **ChatGPT Pro:** веб-сайт должен предоставлять нужный режим данному аккаунту; не предполагать, что через WebView всегда доступны все функции нативного приложения.
3. **Удалённое соединение:** существующий app-server может слушать `127.0.0.1` и быть недоступен с iPhone напрямую. Нужен защищённый маршрут (Tailnet/WSS reverse proxy), не публичный открытый WS.
4. **SideStore LocalDevVPN vs Tailscale:** на iOS нельзя рассчитывать на параллельную работу двух полных VPN; заранее определить процедуру refresh.
5. **Подпись:** бесплатный Apple ID, 7-дневный срок и ограниченные слоты; реальную совместимость unsigned IPA с текущей сборкой SideStore тестировать на устройстве.
6. **Фоновая работа iOS:** не обещать непрерывный WebSocket в фоне или надёжные push без отдельной инфраструктуры.
7. **Работа с живыми сессиями Codex:** UI должен учитывать конкурентные подключения и статус active/idle; не инициировать второй одновременный turn без проверки протокола.

## 13. Ссылки для реализации

- Основной проект: https://github.com/shuto-S/codex-app-mobile
- Донор WebView: https://github.com/Akuma1tko/ChatGPT-WebView
- Официальный Codex App Server API: https://developers.openai.com/codex/app-server
- Apple WKWebsiteDataStore: https://developer.apple.com/documentation/webkit/wkwebsitedatastore
- Google об ограничениях OAuth embedded webviews: https://developers.googleblog.com/en/modernizing-oauth-interactions-in-native-apps-for-better-usability-and-security/
- GitHub macOS runners: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- LiveContainer+SideStore: https://livecontainer.github.io/ru/docs/installation/lc_sidestore
- Impactor: https://github.com/claration/impactor

## 14. Инструкция для следующего coding agent

> Работай непосредственно в форке `shuto-S/codex-app-mobile`. Используй `Akuma1tko/ChatGPT-WebView` как донор минимального Swift-кода, а не как второе приложение внутри контейнера. Не переписывай Codex-клиент с нуля. Реализуй основную вкладку Codex и вторую вкладку ChatGPT Web с отдельной постоянной веб-сессией. Сохрани независимость авторизаций. Выпусти unsigned IPA через GitHub Actions и проверь, что SideStore устанавливает его самостоятельно, не в LiveContainer. При проблемах с OAuth не подделывай cookies или device attestation: зафиксируй воспроизводимый дефект и испытай корректный системный fallback. После успешного MVP переходи к Goal Mode и субагентам. Версионность этого handoff веди **внутри текущего файла**, без новых документов по версиям. Историю изменений поддерживай внизу: **одна строка на изменение**.

---

## История изменений

- **2026-10-26 — v0.1:** создан handoff объединённого iOS CodexAppMobile + ChatGPT-WebView с независимыми аккаунтами, этапами разработки, GitHub Actions, SideStore и критериями приёмки.
