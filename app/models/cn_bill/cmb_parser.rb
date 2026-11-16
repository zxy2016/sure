# CMB (招商银行) PDF transaction statement from the app's 流水打印 feature.
# Layout is columnar: 记账日期 / 货币 / 交易金额 / 联机余额 / 交易摘要 / 对手信息.
# The running balance column lets callers verify continuity and derive the
# opening balance. Text comes from pdftotext -layout (poppler, present in the
# Docker image); Pdf::TextExtractor is the fallback for dev machines.
class CnBill::CmbParser
  # The counterparty is optional on the date line: long names wrap onto the
  # lines above/below it in the counterparty column (e.g. 朝朝宝 redemptions).
  LINE = /\A(\d{4}-\d{2}-\d{2})\s+CNY\s+(-?[\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(\S+)(?:\s+(.+?))?\s*\z/
  RANGE = /(\d{4}-\d{2}-\d{2})\s*--\s*(\d{4}-\d{2}-\d{2})/
  # Counterparty column starts around character 83 in -layout output; wrapped
  # fragments are indented at least this far. Headers/footers start earlier.
  FRAGMENT_COLUMN = 70

  # 户名 printed on the statement; used to spot salary transfers from the
  # user's own payroll card (汇入汇款 with the user as counterparty).
  attr_reader :account_names

  def initialize
    @account_names = []
  end

  def self.parse(content)
    new.parse(content)
  end

  def parse(content)
    parse_many([ content ])
  end

  # Statements are chronological within a file; multiple files are ordered by
  # their printed date range, never by balance (intra-day order matters).
  def parse_many(contents)
    parse_texts(contents.map { |c| extract_text(c) })
  end

  def parse_texts(texts)
    texts.each do |t|
      name = t[/户\s*名：(\S+)/, 1]
      @account_names << name if name.present?
    end
    @account_names.uniq!
    texts.sort_by { |t| t[RANGE, 1] || "9999" }
         .flat_map { |t| parse_text(t) }
         .uniq { |r| [ r[:date], r[:amount], r[:balance] ] }
  end

  def parse_text(text)
    lines = text.lines.map(&:chomp)
    lines.each_with_index.filter_map do |line, i|
      m = LINE.match(line.strip)
      next unless m
      party = (wrapped_above(lines, i) + [ m[5].to_s.strip ] + wrapped_below(lines, i)).compact_blank.join
      { date: m[1], amount: CnBill.amount(m[2]), balance: CnBill.amount(m[3]),
        summary: m[4], party: party }
    end
  end

  private
    def wrapped_above(lines, index)
      fragments = []
      (index - 1).downto(0) do |i|
        break unless fragment?(lines[i])
        fragments.unshift(lines[i].strip)
      end
      fragments
    end

    def wrapped_below(lines, index)
      fragments = []
      (index + 1).upto(lines.size - 1) do |i|
        break unless fragment?(lines[i])
        fragments << lines[i].strip
      end
      fragments
    end

    def fragment?(line)
      return false if line.blank? || LINE.match?(line.strip)
      line.index(/\S/).to_i >= FRAGMENT_COLUMN
    end

    def extract_text(content)
      Tempfile.create([ "cn_cmb", ".pdf" ], binmode: true) do |file|
        file.write(content)
        file.flush
        if pdftotext_available?
          out, _err, status = Open3.capture3("pdftotext", "-layout", file.path, "-")
          return out if status.success? && out.present?
        end
        Pdf::TextExtractor.pages(content).join("\n")
      end
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::EncryptedPDFError => e
      raise CnBill::Error, "无法读取招行 PDF（#{e.class.name.demodulize}），请先解密"
    end

    def pdftotext_available?
      return @pdftotext_available if defined?(@pdftotext_available)
      @pdftotext_available = system("which", "pdftotext", out: File::NULL, err: File::NULL)
    end
end
