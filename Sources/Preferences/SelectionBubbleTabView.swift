//
//  SelectionBubbleTabView.swift
//  MacStroke
//
//  划词气泡偏好页（移植版新增，原版没有）：侧栏独立一页，五段 —— 总开关、触发方式、
//  气泡上的功能、搜索走哪一家、读不到选区时，最后是读取延迟加一小段说明授权和名单。
//
//  为什么不给这一条功能在常规页铺几行了事：它要配的是「一条总开关 + 两条触发方式 +
//  四格各自开关 + 一家搜索引擎 + 一条自定义 URL + 一个自动补 ⌘V + 一个代按 ⌘C + 一个延迟」，
//  一共十三项。
//  常规页本来就是原版最满的一页，十二项压在底部会把导入/导出/重置顶出可视区，
//  而且用户翻不到 —— 独立一页在侧栏里能直接看见名字。
//
//  每一格开关都只管自己：总开关关掉时其余全部灰掉（灰了但不隐藏，隐藏会让人以为功能少做了），
//  「手动唤出」自己关掉时只有那格快捷键灰掉，读取延迟只作用在自动弹出那一路（快捷键按下时
//  人已经等在那儿了，不需要再延迟），所以它跟着「划完字自动弹出」那一条灰。
//  规则本身不在这里判 —— 都在 `SelectionBubbleSettings` 那几个 `popsOn…` / `monitorShortcut`
//  里，那一份是有单测的纯函数；这一页只负责把同一套条件画出来。
//

import SelectionPopup
import Storage
import SwiftUI

struct SelectionBubbleTabView: View {
    @ObservedObject var viewModel: UserPreferences

    var body: some View {
        SettingsPage {
            SettingsSection(title: L("Selection Bubble")) {
                SettingsCard {
                    SettingsRow(L("Selection Bubble master")) {
                        TrailingSwitch(isOn: $viewModel.enableSelectionPopup)
                    }
                    hint(L("Selection Bubble master hint"))
                }
            }

            SettingsSection(title: L("Selection Bubble triggers")) {
                SettingsCard {
                    SettingsRow(L("Selection Bubble auto pop")) {
                        TrailingSwitch(isOn: $viewModel.selectionPopupAutoPop)
                    }
                    .disabled(!viewModel.enableSelectionPopup)
                    hint(L("Selection Bubble auto pop hint"))
                    RowDivider()
                    SettingsRow(L("Selection Bubble manual")) {
                        TrailingSwitch(isOn: $viewModel.selectionPopupShortcutEnabled)
                    }
                    .disabled(!viewModel.enableSelectionPopup)
                    hint(L("Selection Bubble manual hint"))
                    RowDivider()
                    SettingsRow(L("Selection Bubble shortcut")) {
                        ShortcutRecorder(text: $viewModel.selectionPopupShortcut)
                            .frame(width: 200, height: 28)
                    }
                    .disabled(!canUseShortcutRow)
                    hint(L("Selection Bubble shortcut hint"))
                }
            }

            SettingsSection(title: L("Selection Bubble actions")) {
                SettingsCard {
                    ForEach(Array(SelectionBubbleAction.allCases.enumerated()), id: \.element) { offset, action in
                        if offset > 0 { RowDivider() }
                        SettingsRow(L(action.titleKey)) {
                            TrailingSwitch(isOn: actionBinding(action))
                        }
                        .disabled(!viewModel.enableSelectionPopup)
                        hint(L(action.hintKey))
                    }
                }
                // 四格全关是「功能开着但什么都不会发生」的唯一一种配法，界面上必须说破，
                // 否则用户只会以为划词气泡坏了。
                if viewModel.enableSelectionPopup && enabledActionCount == 0 {
                    Text(L("Selection Bubble no action warning"))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }

            // 搜索那一格走哪一家。排在四格后面：它服务的就是其中「搜索」那一格，
            // 隔着一整段「读不到选区时」就看不出这层从属关系了。
            //
            // 为什么是一格下拉 + 一个文本框，而不是十四行「每家一颗开关」：这一格永远只用一家，
            // 十四颗开关要表达的还是「选中了哪一颗」，白多铺十三行（同 issue #53/#59 的口径 ——
            // 一个能力只给一组控件）。
            SettingsSection(title: L("Selection Bubble engine")) {
                SettingsCard {
                    SettingsRow(L("Selection Bubble engine row")) {
                        Picker("", selection: engineBinding) {
                            Section(header: Text(L("Selection Bubble engine group search"))) {
                                ForEach(SelectionBubbleSearchEngine.searchEngines, id: \.self) { engine in
                                    Text(L(engine.titleKey)).tag(engine)
                                }
                            }
                            Section(header: Text(L("Selection Bubble engine group ai"))) {
                                ForEach(SelectionBubbleSearchEngine.aiEngines, id: \.self) { engine in
                                    Text(L(engine.titleKey)).tag(engine)
                                }
                            }
                            Section(header: Text(L("Selection Bubble engine group custom"))) {
                                Text(L(SelectionBubbleSearchEngine.custom.titleKey))
                                    .tag(SelectionBubbleSearchEngine.custom)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .disabled(!canUseEngineRow)
                    hint(L("Selection Bubble engine hint"))
                    RowDivider()
                    SettingsRow(L("Selection Bubble custom URL")) {
                        TextField("https://example.com/search?q={query}",
                                  text: $viewModel.selectionPopupSearchCustomURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 300)
                            .disabled(!canUseCustomURLRow)
                    }
                    hint(L("Selection Bubble custom URL hint"))
                    RowDivider()
                    // 「自动贴那一下」跟在这一家后面，因为它只对**这一家当下不吃 URL 预填**的那些页有意义。
                    // 摆在引擎区块里而不是「读不到选区时」那一节：那一节管的是**取字**，这一行管的是
                    // **把字交出去**，混在一起会让人以为它和代按 ⌘C 是同一手的两半。
                    SettingsRow(L("Selection Bubble auto paste")) {
                        TrailingSwitch(isOn: $viewModel.selectionPopupAutoPaste)
                    }
                    .disabled(!canUseAutoPasteRow)
                    hint(L("Selection Bubble auto paste hint"))
                }
                // 选了自定义却没填（或填得不像个网址）：消费端会退回默认那一家。
                // 这一条必须说破 —— 否则用户以为走的是自己写的那条，实际开的是 Google，
                // 而界面上看着一切正常（和「代按 ⌘C 被快捷键挡住」那一处同一个理由）。
                if showsCustomURLEmptyWarning {
                    Text(L("Selection Bubble custom URL empty warning"))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                // 气泡快捷键被录成单纯 ⌘V 时，`searchAutoPaste` 那句纯函数会把这一手整个挡掉
                // （拆环，理由同代按 ⌘C 那一处）。界面必须跟着说破：开关开着却一次不生效。
                if showsAutoPasteShortcutWarning {
                    Text(L("Selection Bubble auto paste shortcut warning"))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }

            // 读不到选区时那一手：单独一段，不并进「触发方式」也不并进「读取时机」。
            // 理由是它管的既不是怎么唤出、也不是等多久，而是「换一种机制去拿字」——
            // 而这一手要动用户的粘贴板，把它混在别人的一堆滑块和开关中间，等于替他把代价藏起来。
            SettingsSection(title: L("Selection Bubble fallback")) {
                SettingsCard {
                    SettingsRow(L("Selection Bubble copy fallback")) {
                        TrailingSwitch(isOn: $viewModel.selectionPopupCopyFallback)
                    }
                    .disabled(!viewModel.enableSelectionPopup)
                    hint(L("Selection Bubble copy fallback hint"))
                }
                // 气泡快捷键被录成单纯 ⌘C 时，这一手会被那句纯函数挡掉（见 `canUseCopyFallback` 的注释）。
                // 界面上必须说破：开关明明开着、却一次都不生效，是「看着能配其实配不动」那类最难查的坏。
                if viewModel.enableSelectionPopup && viewModel.selectionPopupCopyFallback
                    && copyFallbackBlockedByShortcut {
                    Text(L("Selection Bubble copy fallback shortcut warning"))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }

            SettingsSection(title: L("Selection Bubble timing")) {
                SettingsCard {
                    SettingsRow(L("Selection Bubble read delay")) {
                        HStack(spacing: 8) {
                            Text("\(viewModel.selectionPopupReadDelay)")
                                .foregroundColor(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            Slider(value: Binding(
                                get: { Double(viewModel.selectionPopupReadDelay) },
                                set: { viewModel.selectionPopupReadDelay = Int($0) }
                            // 步长取自模块那份常量：界面写死一个数字，将来阈值一改就会出现
                            // 「滑不到边界、也滑不回默认」的格子。
                            ), in: delayRange,
                               step: Double(SelectionBubbleSettings.readDelayStepMilliseconds))
                            .frame(width: 210)
                            Text(L("Selection Bubble milliseconds unit"))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!canUseDelayRow)
                    hint(L("Selection Bubble read delay hint"))
                }
                // 授权与名单这两件事不体现在任何一格的开关上，却决定了「为什么没弹」，
                // 所以写在页面最后而不是塞进某一行的小字里。
                Text(L("Selection Bubble footnotes"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 哪一格该灰

    /// 快捷键录制框：总开关、或「手动唤出」自己关掉时都该灰。灰了就等于
    /// `SelectionBubbleSettings.monitorShortcut` 交出空串（那只监听整个不挂），
    /// 界面和消费端必须同一套条件，否则用户会以为录进去的键还有效。
    private var canUseShortcutRow: Bool {
        viewModel.enableSelectionPopup && viewModel.selectionPopupShortcutEnabled
    }

    /// 「手动快捷键唤出」单独关掉，只该影响快捷键那一块：自动弹和四格都不许跟着灰。
    /// 反过来的坏（一关就把整页灰了）用户只会以为划词气泡坏了。
    private var canUseDelayRow: Bool {
        viewModel.enableSelectionPopup && viewModel.selectionPopupAutoPop
    }

    /// 搜索走哪一家：它只服务「搜索」那一格，所以那一格关掉时这里就该灰 ——
    /// 灰掉而不是隐藏，理由和别处一样（隐藏会让人以为功能少做了一项）。
    private var canUseEngineRow: Bool {
        viewModel.enableSelectionPopup && viewModel.selectionPopupActionSearch
    }

    /// 自定义 URL 那个文本框：只有下拉真选了「自定义」才编辑得动。
    private var canUseCustomURLRow: Bool {
        canUseEngineRow && selectedEngine == .custom
    }

    /// 下拉当前选中的那一家。**读的是 `UserPreferences` 里那串，经 `from(rawValue:)` 认一遍**，
    /// 和消费端同一句：库里存了个认不出的 id 时，这里显示的是退回后的那一家，
    /// 而不是下拉里根本没有的一项（画出来是一条空白，看着像页面坏了）。
    private var selectedEngine: SelectionBubbleSearchEngine {
        SelectionBubbleSearchEngine.from(rawValue: viewModel.selectionPopupSearchEngine)
    }

    /// 「选了自定义、但那一栏还不像个网址」—— 消费端这时候走的是默认那一家（见
    /// `resolvedTemplate`）。判据也是它那一句的同一份（`looksLikeURL` 是 public 就为这个），
    /// 页面自己再判一遍就会出现黄字说 A、实际开 B。
    private var showsCustomURLEmptyWarning: Bool {
        viewModel.enableSelectionPopup && viewModel.selectionPopupActionSearch
            && selectedEngine == .custom
            && !SelectionBubbleSearchEngine.looksLikeURL(
                viewModel.selectionPopupSearchCustomURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 下拉和那串之间走枚举：界面上永远只有一个值能选，`set` 写回 rawValue 落盘。
    /// 绑到字符串属性上再自己映射一遍的话，加一家就要记得补一处，漏了是那类
    /// 「下拉里点了、库里的值没变」的静默坏。
    private var engineBinding: Binding<SelectionBubbleSearchEngine> {
        Binding(get: { selectedEngine },
                set: { viewModel.selectionPopupSearchEngine = $0.rawValue })
    }

    /// 「代按 ⌘C」这一手是不是被那条**拆环的闸**挡住了：气泡快捷键录成了单纯的 ⌘C。
    /// 判据本身在 `SelectionBubbleSettings.canUseCopyFallback`（那份是有单测的纯函数），
    /// 这里只是把同一个条件画出来 —— 页面自己再判一遍的话，两处迟早对不上。
    private var copyFallbackBlockedByShortcut: Bool {
        SelectionBubbleSettings.isPlainCommandC(viewModel.selectionPopupShortcut)
    }

    /// 「打开之后自动贴那一下」的可用条件：**和「搜索走哪一家」同一档** —— 它只服务搜索那一格，
    /// 那一格关掉时这里没有对象可贴。这里**不看**下拉选的是哪家：真能 URL 预填的那六家点了这颗
    /// 开关也确实什么都不会发生（`searchAutoPaste` 里那条 `copiesTextFirst` 挡着），但那属于
    /// 「这一家轮不到」，不是「这一格坏了」，把它画成灰的反而让人以为按不动是毛病。
    private var canUseAutoPasteRow: Bool { canUseEngineRow }

    /// 气泡快捷键被录成**单纯的 ⌘V** —— 那时候 `searchAutoPaste` 会压根不上场（拆环，
    /// 见那句纯函数的注释），而开关看着是开的。和「代按 ⌘C 被快捷键挡住」那一处同一个理由：
    /// 这种「开着却一次不生效」必须说破，不然用户只会以为这一手坏了。
    private var showsAutoPasteShortcutWarning: Bool {
        viewModel.enableSelectionPopup && viewModel.selectionPopupActionSearch
            && viewModel.selectionPopupAutoPaste
            && SelectionBubbleSettings.isPlainCommandV(viewModel.selectionPopupShortcut)
    }

    private var enabledActionCount: Int {
        [viewModel.selectionPopupActionCopy,
         viewModel.selectionPopupActionSearch,
         viewModel.selectionPopupActionTranslate,
         viewModel.selectionPopupActionSpeak].filter { $0 }.count
    }

    /// 读取延迟滑杆的刻度（毫秒）取自模块那份阈值：界面写死一份数字，将来消费端改阈值
    /// 就会出现「滑到头还算不出边界」的错配。
    private var delayRange: ClosedRange<Double> {
        let range = SelectionBubbleSettings.readDelayMillisecondsRange
        return Double(range.lowerBound) ... Double(range.upperBound)
    }

    /// 四格的绑定从一个枚举走：这里漏接一个开关的话，界面上那颗开关拨了没反应，
    /// 而这类「看着能配其实配不动」的坏在离屏取证里最难看出来 —— 所以开关和
    /// `UserPreferences` 那四个属性只由这一句映射连着，加第五格只要往枚举里加一档。
    private func actionBinding(_ action: SelectionBubbleAction) -> Binding<Bool> {
        Binding(get: {
            switch action {
            case .copy: return viewModel.selectionPopupActionCopy
            case .search: return viewModel.selectionPopupActionSearch
            case .translate: return viewModel.selectionPopupActionTranslate
            case .speak: return viewModel.selectionPopupActionSpeak
            }
        }, set: { value in
            switch action {
            case .copy: viewModel.selectionPopupActionCopy = value
            case .search: viewModel.selectionPopupActionSearch = value
            case .translate: viewModel.selectionPopupActionTranslate = value
            case .speak: viewModel.selectionPopupActionSpeak = value
            }
        })
    }

    /// 行下面那行小字（和截图页同一个排法）：卡片的圆角内，说明紧贴它解释的那一行。
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }
}
