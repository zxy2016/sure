# Alipay transaction detail export ("开具交易流水证明 → 用于个人对账").
# GB18030-encoded CSV with ~24 metadata lines before the 交易时间 header.
# 收/支 is 支出/收入/不计收支; 不计收支 rows need case-by-case handling
# (余额宝 earnings are income, 因公付 is company money, refunds cancel out).
class CnBill::AlipayParser
  HEADER_PREFIX = "交易时间,".freeze

  def self.parse(content)
    new.parse(content)
  end

  def parse(content)
    text = decode(content)
    lines = text.lines.map(&:chomp)
    header_index = lines.index { |l| l.start_with?(HEADER_PREFIX) }
    raise CnBill::Error, "未找到支付宝账单表头（交易时间）" unless header_index

    table = CSV.parse(lines[header_index..].join("\n"), headers: true, liberal_parsing: true)
    table.filter_map do |r|
      next unless r["交易时间"].to_s.match?(/\A\d{4}-\d{2}-\d{2}/)
      {
        date: CnBill.date(r["交易时间"]),
        category_raw: r["交易分类"].to_s.strip,
        party: CnBill.clean(r["交易对方"]),
        product: CnBill.clean(r["商品说明"]),
        direction: r["收/支"].to_s.strip,
        amount: CnBill.amount(r["金额"]),
        method: r["收/付款方式"].to_s.strip,
        status: r["交易状态"].to_s.strip,
        txn_id: CnBill.clean(r["交易订单号"]),
        note: CnBill.clean(r["备注"])
      }
    end.uniq { |r| r[:txn_id].presence || [ r[:date], r[:amount], r[:party] ] }
  end

  private
    def decode(content)
      utf8 = content.dup.force_encoding(Encoding::UTF_8)
      return utf8 if utf8.valid_encoding?
      content.dup.force_encoding(Encoding::GB18030).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
end
