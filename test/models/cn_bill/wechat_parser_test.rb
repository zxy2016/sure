require "test_helper"

class CnBill::WechatParserTest < ActiveSupport::TestCase
  HEADERS = %w[交易时间 交易类型 交易对方 商品 收/支 金额(元) 支付方式 当前状态 交易单号 商户单号 备注].freeze

  test "parses xlsx with shared strings and numeric amounts" do
    rows = CnBill::WechatParser.parse(build_xlsx([
      [ "2026-10-31 08:12:21", "扫二维码付款", "淡定", "二维码收款", "支出", "10.5", "零钱", "已转账", "W001", "/", "/" ],
      [ "2026-10-30 19:30:00", "转账", "车友", "微信转账", "收入", "10", "/", "已转入零钱通", "W002", "/", "/" ]
    ]))

    assert_equal 2, rows.size
    assert_equal "2026-10-31", rows[0][:date]
    assert_equal BigDecimal("10.5"), rows[0][:amount]
    assert_equal "支出", rows[0][:direction]
    assert_equal "零钱", rows[0][:method]
    assert_equal "", rows[1][:method] # "/" normalizes to blank
  end

  test "converts excel serial dates" do
    serial = (Date.new(2026, 10, 3) - Date.new(1899, 12, 30)).to_i
    rows = CnBill::WechatParser.parse(build_xlsx([
      [ serial, "其他", "红包活动", "/", "收入", "0.38", "/", "已到账", "W003", "/", "/" ]
    ]))
    assert_equal "2026-10-03", rows.first[:date]
  end

  test "deduplicates by transaction id" do
    row = [ "2026-10-31 08:12:21", "商户消费", "商店", "/", "支出", "8", "零钱", "支付成功", "W004", "/", "/" ]
    assert_equal 1, CnBill::WechatParser.parse(build_xlsx([ row, row ])).size
  end

  test "raises when header row is missing" do
    assert_raises(CnBill::Error) { CnBill::WechatParser.parse(build_xlsx([ [ "just", "metadata" ] ])) }
  end

  private
    # Minimal xlsx: all cells as shared strings except pure numbers.
    def build_xlsx(data_rows)
      all_rows = [ [ "微信支付账单明细" ], HEADERS ] + data_rows
      strings = []
      sheet = +%(<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>)
      all_rows.each_with_index do |row, ri|
        sheet << %(<row r="#{ri + 1}">)
        row.each_with_index do |value, ci|
          ref = "#{("A".ord + ci).chr}#{ri + 1}"
          if value.is_a?(Numeric) || value.to_s.match?(/\A\d+(\.\d+)?\z/)
            sheet << %(<c r="#{ref}"><v>#{value}</v></c>)
          else
            idx = strings.index(value.to_s) || (strings << value.to_s; strings.size - 1)
            sheet << %(<c r="#{ref}" t="s"><v>#{idx}</v></c>)
          end
        end
        sheet << "</row>"
      end
      sheet << "</sheetData></worksheet>"

      sst = +%(<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">)
      strings.each { |s| sst << "<si><t>#{ERB::Util.html_escape(s)}</t></si>" }
      sst << "</sst>"

      buffer = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry("xl/sharedStrings.xml")
        zip.write(sst)
        zip.put_next_entry("xl/worksheets/sheet1.xml")
        zip.write(sheet)
      end
      buffer.string
    end
end
