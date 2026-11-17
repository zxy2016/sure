# Parsers and conversion for Chinese personal bill exports (WeChat Pay xlsx,
# Alipay GB18030 CSV, CMB PDF statement) into Sure transaction-import CSVs.
#
# Amounts in the generated CSVs are inflows-positive; the created imports use
# signage_convention "inflows_positive" so Sure stores outflows positive.
module CnBill
  CSV_HEADERS = %w[date amount name category tags notes].freeze

  # Channel defaults: used to find-or-create the target account and to label rows.
  CHANNELS = {
    wechat: { account_name: "微信钱包", tag: "微信", accept: ".xlsx" },
    alipay: { account_name: "支付宝", tag: "支付宝", accept: ".csv" },
    cmb:    { account_name: "招商银行储蓄卡", tag: "招行", accept: ".pdf" },
    ccb:    { account_name: "建设银行工资卡", tag: "建行", accept: ".xls,.xlsx" }
  }.freeze

  LARGE_TRANSFER_THRESHOLD = 10_000
  LARGE_TRANSFER_TAG = "大额转账".freeze
  WEALTH_SWEEP_TAG = "理财划转".freeze
  SWEEP_ACCOUNT_NAME = "朝朝宝".freeze
  WALLET_CHANNEL_TAG = "零钱渠道".freeze
  SELF_TRANSFER_CATEGORY = "人情往来:转账".freeze

  class Error < StandardError; end

  class << self
    def amount(value)
      BigDecimal(value.to_s.gsub(/[,\s¥￥]/, ""))
    rescue ArgumentError
      raise Error, "invalid amount: #{value.inspect}"
    end

    def date(value)
      case value
      when Time, DateTime then value.to_date.iso8601
      when Date then value.iso8601
      else value.to_s.strip[0, 10]
      end
    end

    # Bill exports use "/" (and sometimes dashes) for empty cells.
    def clean(value)
      text = value.to_s.strip
      text.in?([ "/", "-", "—" ]) ? "" : text
    end

    def csv_for(rows)
      CSV.generate do |csv|
        csv << CSV_HEADERS
        rows.sort_by { |r| r[:date] }.each do |r|
          csv << CSV_HEADERS.map { |h| r[h.to_sym] }
        end
      end
    end

    def row(date:, amount:, name:, category: "", tags: "", notes: "")
      { date: date, amount: format("%.2f", amount), name: name.to_s.truncate(120),
        category: category, tags: tags, notes: notes.to_s.truncate(400) }
    end
  end
end
