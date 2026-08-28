import SwiftUI

/// 我的收藏页（iOS 版）：按自建分组浏览。
/// 收藏数据只存本地（FavoriteStore），不走服务端，也不上传。
///
/// 触屏交互替代 Mac 版右键菜单：长按卡片弹出「移除收藏（带确认）/移动到分组」；
/// 分组的新建 / 改名 / 删除在分组选择行上操作。
struct FavoritesView: View {

    @ObservedObject private var favorites = FavoriteStore.shared
    @State private var folder = "默认"
    /// 绑定自 App 的收藏栈 NavigationStack
    @Binding var path: [Route]

    init(path: Binding<[Route]>) {
        _path = path
    }

    // 分组管理
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showRenameFolder = false
    @State private var renameText = ""
    @State private var confirmRemoveFolder = false

    // 取消收藏确认
    @State private var pendingRemove: FavoriteStore.Entry?
    @State private var showRemoveConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            folderBar
            grid
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let meta):
                AlbumDetailView(meta: meta, path: $path)
            case .categories, .personalized, .recent:
                EmptyView()   // 本页只会推入详情页，这三个 case 仅在浏览 tab 顶层出现
            }
        }
        // 新建分组（iOS 16 起 alert 支持内嵌 TextField）
        .alert("新建分组", isPresented: $showNewFolder) {
            TextField("分组名称", text: $newFolderName)
            Button("确定") {
                favorites.addFolder(newFolderName)
                if favorites.folders.contains(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)),
                   !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    folder = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        } message: {
            Text("收藏会按分组存放，服务端不参与。")
        }
        // 分组改名
        .alert("重命名分组「\(folder)」", isPresented: $showRenameFolder) {
            TextField("新名称", text: $renameText)
            Button("确定") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                favorites.renameFolder(folder, to: renameText)
                // 改名成功跟随新名；目标已存在（并入）也选它；无效输入退回默认
                folder = favorites.folders.contains(trimmed) ? trimmed : "默认"
                renameText = ""
            }
            Button("取消", role: .cancel) { renameText = "" }
        }
        // 删除分组（内容退回默认，不删收藏）
        .confirmationDialog("删除分组「\(folder)」？",
                            isPresented: $confirmRemoveFolder,
                            titleVisibility: .visible) {
            Button("删除分组", role: .destructive) {
                favorites.removeFolder(folder)
                folder = "默认"
            }
        } message: {
            Text("组内收藏会退回「默认」分组，不会被删除。")
        }
        // 取消收藏确认
        .confirmationDialog("移除收藏？",
                            isPresented: $showRemoveConfirm,
                            titleVisibility: .visible,
                            presenting: pendingRemove) { entry in
            Button("移除「\(entry.meta.title)」", role: .destructive) {
                favorites.remove(entry.meta.id)
            }
        }
    }

    // MARK: - 分组行

    private var folderBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("分组", selection: $folder) {
                    ForEach(favorites.folders, id: \.self) { f in
                        Text("\(f)（\(favorites.count(in: f))）").tag(f)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text("\(folder)（\(favorites.count(in: folder))）").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.subheadline)
            }

            Spacer(minLength: 8)

            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("新建分组")

            if folder != "默认" {
                Menu {
                    Button {
                        renameText = folder
                        showRenameFolder = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmRemoveFolder = true
                    } label: {
                        Label("删除分组", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 网格

    private var grid: some View {
        let shown = favorites.entries(in: folder)
        return ScrollView {
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart").font(.largeTitle).foregroundStyle(.secondary)
                    Text("这个分组还没有收藏").foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                    ForEach(shown) { entry in
                        Button { path.append(.album(entry.meta)) } label: {
                            AlbumCard(meta: entry.meta)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingRemove = entry
                                showRemoveConfirm = true
                            } label: {
                                Label("移除收藏", systemImage: "heart.slash")
                            }
                            Divider()
                            ForEach(favorites.folders.filter { $0 != entry.folder }, id: \.self) { f in
                                Button("移动到「\(f)」") {
                                    favorites.move(entry.meta.id, to: f)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}
