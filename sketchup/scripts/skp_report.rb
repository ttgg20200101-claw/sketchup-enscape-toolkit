# 只读：统计当前打开模型的组件 / 材质 / 标签，写出 JSON 报告到桌面。
# 不修改、不保存模型。适配 SketchUp 2020 (Ruby 2.5)。
require 'json'

model = Sketchup.active_model
defs  = model.definitions.reject { |d| d.group? || d.image? }

report = {
  'model'      => model.path,
  'sketchup'   => Sketchup.version,
  'generated'  => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
  'components' => defs.map { |d| { 'name' => d.name, 'instances' => d.count_used_instances } }
                      .sort_by { |h| -h['instances'] },
  'groups'     => model.definitions.count(&:group?),
  'materials'  => model.materials.map(&:display_name).sort,
  'tags'       => model.layers.map(&:name)
}

out = File.join(Dir.home, 'Desktop', 'skp_report.json')
File.write(out, JSON.pretty_generate(report))

puts "OK -> #{out}"
puts "组件定义 #{report['components'].size} 个 / 组 #{report['groups']} 个 / 材质 #{report['materials'].size} 个 / 标签 #{report['tags'].size} 个"
report['components'].first(10).each { |c| puts "  #{c['instances']}x  #{c['name']}" }
