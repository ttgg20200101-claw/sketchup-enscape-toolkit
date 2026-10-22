# encoding: UTF-8
# 菜单命令与对话框。
require 'json'
require 'tmpdir'
require 'fileutils'

module GZAsset
  module Commands
    OTHER_SNAPSHOT = '（选其他快照文件…）'.freeze

    module_function

    def guard
      yield
    rescue StandardError => e
      Sketchup.status_text = ''
      puts "[工装资产] #{e.class}: #{e.message}\n#{(e.backtrace || []).first(10).join("\n")}"
      UI.messagebox("出错了：#{e.message}\n\n详细信息在「窗口 → Ruby 控制台」。")
    end

    # ---------------- 索引目录 ----------------

    def ensure_index
      Library.index_dir || choose_index
    end

    def choose_index
      d = UI.select_directory(title: '选择资产索引目录（扫描器生成 assets.json 的那个文件夹）')
      return nil unless d
      Library.index_dir = d
      d
    end

    # ---------------- 锁定 ----------------

    def lock
      model = Sketchup.active_model
      return unless (idx = ensure_index)
      input = UI.inputbox(['备注（可空）'], [''], '锁定当前效果')
      return unless input
      dir = File.join(Library.snapshot_root(idx, model), Time.now.strftime('%Y%m%d_%H%M%S'))
      Sketchup.status_text = '工装资产：正在锁定…'
      state = State.capture(model, dir, input[0].to_s.tr('|', '/'))
      State.save(state, dir)
      Library.write_meta(dir, state)
      Sketchup.status_text = ''
      tex = state['materials'].count { |m| m['texture'] }
      UI.messagebox("已锁定。\n\n" \
                    "材质 #{state['materials'].size} 个（带贴图 #{tex} 个）\n" \
                    "灯光/组件设置 #{state['entities'].size} 处\n" \
                    "视觉设置字典 #{state['model_dicts'].size} 个\n\n" \
                    "保存在：#{dir}")
    end

    # ---------------- 比对 / 回滚 ----------------

    def pick_snapshot(idx, model, title)
      snaps = Library.list_snapshots(idx, model)
      return pick_file if snaps.empty?
      labels = snaps.map { |s| "#{s['created_at']}  #{s['label']}".strip }
      choice = UI.inputbox(['快照'], [labels.first], [(labels + [OTHER_SNAPSHOT]).join('|')], title)
      return nil unless choice
      return pick_file if choice[0] == OTHER_SNAPSHOT
      snaps[labels.index(choice[0])]['dir']
    end

    def pick_file
      f = UI.openpanel('选择快照里的 state.json', '', 'state.json|state.json||')
      f ? File.dirname(f) : nil
    end

    def diff_against(model, dir)
      snap = State.load(dir)
      Sketchup.status_text = '工装资产：正在读取当前状态…'
      tmp = Dir.mktmpdir('gz_asset')
      begin
        cur = State.capture(model, tmp)
        [snap, State.compare(snap, cur)]
      ensure
        FileUtils.rm_rf(tmp)
        Sketchup.status_text = ''
      end
    end

    def diff
      model = Sketchup.active_model
      return unless (idx = ensure_index)
      return unless (dir = pick_snapshot(idx, model, '与快照比对'))
      snap, changes = diff_against(model, dir)
      show_report("当前模型 vs 快照 #{snap['created_at']} #{snap['label']}", changes, [])
    end

    def rollback
      model = Sketchup.active_model
      return unless (idx = ensure_index)
      return unless (dir = pick_snapshot(idx, model, '回滚到快照'))
      snap, changes = diff_against(model, dir)
      todo = changes.select { |c| c['restore_key'] }
      if todo.empty?
        UI.messagebox('当前状态和快照一致，不需要回滚。')
        return
      end
      n = Hash.new(0)
      todo.each { |c| n[c['scope']] += 1 }
      added = changes.size - todo.size
      msg = "将改回：\n\n" \
            "材质 #{n['材质']} 个\n视觉设置 #{n['视觉设置']} 处\n灯光/组件 #{n['灯光/组件']} 处\n"
      msg += "\n快照之后新增的 #{added} 项不会删除。\n" if added > 0
      msg += "\n回滚后可以用 Ctrl+Z 一步撤销。继续？"
      return unless UI.messagebox(msg, MB_YESNO) == IDYES
      done, skipped = State.restore(model, dir, snap, todo)
      show_report("已回滚到快照 #{snap['created_at']} #{snap['label']}", done, skipped)
    end

    # ---------------- 入库 / 投放 ----------------

    def harvest
      model = Sketchup.active_model
      return unless (idx = ensure_index)
      sel = model.selection.to_a
      defs = sel.grep(Sketchup::ComponentInstance).map(&:definition).uniq
      groups = sel.grep(Sketchup::Group).size
      if defs.empty?
        UI.messagebox(groups > 0 ? '选中的是群组。群组不能入库，请先右键 →「创建组件」。' : '请先选中要入库的组件。')
        return
      end
      default_name = defs.size == 1 ? defs[0].name : "（#{defs.size} 个组件，各用原名）"
      input = UI.inputbox(['名称', '标签（空格分隔，可空）'], [default_name, ''], '入库')
      return unless input
      name = defs.size == 1 ? input[0].to_s.strip : ''
      tags = input[1].to_s.split(/[\s,，]+/).reject(&:empty?)
      Sketchup.status_text = '工装资产：正在入库…'
      added = Library.harvest(model, idx, defs, name, tags)
      Sketchup.status_text = ''
      note = groups > 0 ? "\n\n另有 #{groups} 个群组被跳过（群组需先做成组件）。" : ''
      UI.messagebox("已入库 #{added.size} 个组件。#{note}")
    end

    def browser
      return unless (idx = ensure_index)
      @browser.close if @browser && @browser.visible?
      dlg = UI::HtmlDialog.new(dialog_title: '工装资产库', preferences_key: 'GZAsset.browser',
                               width: 960, height: 680, style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_file(File.join(GZAsset::PLUGIN_DIR, 'ui', 'browser.html'))
      dlg.add_action_callback('ready') do |_ctx|
        dlg.execute_script("render(#{js_json(Library.browser_items(idx))})")
      end
      dlg.add_action_callback('place') do |_ctx, path|
        guard { place(path.to_s) }
      end
      dlg.show
      @browser = dlg
    end

    def place(path)
      unless File.file?(path)
        UI.messagebox("找不到文件：\n#{path}")
        return
      end
      mb = File.size(path) / 1_048_576.0
      if mb > 100
        q = format("这个文件有 %.0f MB，载入可能要几分钟。继续？", mb)
        return unless UI.messagebox(q, MB_YESNO) == IDYES
      end
      Sketchup.status_text = '工装资产：正在载入…'
      Library.place(Sketchup.active_model, path)
      Sketchup.status_text = ''
    end

    # ---------------- 报告对话框 ----------------

    def show_report(title, changes, skipped)
      dlg = UI::HtmlDialog.new(dialog_title: '工装资产', preferences_key: 'GZAsset.report',
                               width: 820, height: 620, style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_file(File.join(GZAsset::PLUGIN_DIR, 'ui', 'report.html'))
      data = { 'title' => title, 'changes' => changes, 'skipped' => skipped }
      dlg.add_action_callback('ready') { |_ctx| dlg.execute_script("render(#{js_json(data)})") }
      dlg.show
      @report = dlg
    end

    # U+2028/U+2029 在旧版 Chromium 的 JS 字符串里非法，要转义
    def js_json(obj)
      JSON.generate(obj, allow_nan: true).gsub(" ", ' ').gsub(" ", ' ')
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('工装资产')
      menu.add_item('锁定当前效果…') { guard { lock } }
      menu.add_item('与快照比对…') { guard { diff } }
      menu.add_item('回滚到快照…') { guard { rollback } }
      menu.add_separator
      menu.add_item('选中组件入库…') { guard { harvest } }
      menu.add_item('资产库 / 投放…') { guard { browser } }
      menu.add_separator
      menu.add_item('设置索引目录…') { guard { choose_index } }
      file_loaded(__FILE__)
    end
  end
end
