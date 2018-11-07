# Report generator for OPP
require 'csv'
require 'pg'
require 'builder'
require 'fileutils'

paymentlist_file = 'payments_accounting_report_filtered.csv'
assoclist_file = 'assoc_list.csv'
exceptions_file = 'exceptions.txt'
txn_query = File.read('txn_query.sql')

report = {}
assoc_list = {}
exceptions = []
blank_row = {'TXN ID' => 0, 'TXN Date' => 0, 'PSP Reference' => 0, 'Method' => '', 'Payment Status' => '', 'Details' => '{}', 'App ID' => 0, 'Opp Id' => 0, 'Opp Title' => '', 'Host LC' => '', 'Host MC' => '', 'Host Rgn' => '', 'Person ID' => 0, 'Person Name' => '', 'Home LC' => '', 'Home MC' => '', 'Home RG' => ''}

puts 'Opening database connection.'
begin
  con = PG.connect :host => DB_HOST,
                   :dbname => DB_NAME,
                   :user => DB_USER,
                   :password => DB_PASS

  puts "Connection opened successfully.\nRunning query."
  txn_arr = con.exec txn_query
  puts 'Query successful.'

rescue PG::Error => e
  puts e.message
  exit

ensure
  con.close if con
  puts 'Connection to DB closed.'
end

puts "Opening #{assoclist_file}."
CSV.foreach(assoclist_file, headers: true) {|row| assoc_list[row['Merchant']] = row['MC']}
puts 'Acquired MC<->Merchant Association List.'

puts "Opening #{exceptions_file}."
CSV.foreach(exceptions_file, headers: true) {|row| exceptions.push(row)}
puts 'Exceptions list generated.'

puts "Opening #{paymentlist_file}."

earliest_date = nil
latest_date = 0

CSV.foreach paymentlist_file, headers: true do |list_row|
  # Ignore payouts from the report
  # next if row['Payment Method'] == 'bankTransfer_IBAN' or row['PSP Reference'].nil?

  list_row_arr = list_row.to_hash

  # Ignore payouts from the exceptions list
  next if exceptions.include? list_row_arr['PSP Reference']

  next unless %w(SettledBulk Refused Settled RefundedBulk).include? list_row_arr['Record Type']

  this_date = Date.parse list_row_arr['Booking Date']
  if earliest_date.nil?
    earliest_date = this_date
  else
    earliest_date = earliest_date < this_date ? earliest_date : this_date
  end
  latest_date = this_date > latest_date ? this_date : latest_date

  print "Checking #{list_row_arr['Psp Reference']}: "
  txn = txn_arr.find {|txn_row| txn_row['PSP Reference'] == list_row_arr['Psp Reference']}

  if txn.nil?
    puts 'Not found. Using dummy data.'
    txn = blank_row.merge list_row_arr
    # We need to generate it anyway
  else
    # Convert the refunds and chargebacks into negative payments
    if %w(Refunded RefundedBulk Chargeback).include? list_row_arr['Record Type']
      list_row_arr['Main Amount'] = (-(list_row_arr['Main Amount'].to_i)).to_s
    end

    txn = txn.merge(list_row_arr)
    puts 'Found.'
  end

  report[list_row_arr['Merchant Account']] = [] if report[list_row_arr['Merchant Account']].nil?
  report[list_row_arr['Merchant Account']].push txn
end

puts "Generated transactions reports.\n"

report.each do |merchant, txns|
  print "Generating files for #{merchant}"

  # Calculate the totals
  overall_totals = {}
  txns.each do |txn|
    next if %w(Refused).include? txn['Record Type']
    overall_totals[txn['Main Currency']] = 0 if overall_totals[txn['Main Currency']].nil?
    overall_totals[txn['Main Currency']] += txn['Main Amount'].to_f
  end
  overall_no_txns = txns.length

  # Break the transactions into per office tables amounts
  txns_local = {}
  txns.each do |txn|
    txns_local[txn['Home LC']] = [] if txns_local[txn['Home LC']].nil?
    txns_local[txn['Home LC']].push(txn)
  end

  # Calculate the total amounts
  totals = {}
  txns_local.each do |office_name, txn_local|
    txn_local.each do |txn|
      next if %w(Refused).include? txn['Record Type']
      totals[office_name] = {} if totals[office_name].nil?
      totals[office_name][txn['Main Currency']] = 0 if totals[office_name][txn['Main Currency']].nil?
      totals[office_name][txn['Main Currency']] += txn['Main Amount'].to_f
    end
  end

  # Calculate no. of transactions
  no_transactions = {}
  txns_local.each {|office_name, txn_local| no_transactions[office_name] = txn_local.length}

  # Generate HTML file
  src = "<html><head><title>Payout Report - #{merchant}</title></head></html><body style='font-family: Lato, Arial, sans-serif'>"
  src += "<h1>Payout Report for AIESEC in #{merchant} for date range #{earliest_date.strftime('%d/%m/%Y')} - #{latest_date.strftime('%d/%m/%Y')}</h1>"

  src += '<br><br><b>Totals</b><br>Amount acquired: '
  overall_totals.each {|key, value| src += "%.2f #{key}<br>" % value}
  src += "No. of transactions: #{overall_no_txns}<br>"
  src += "Transaction charges: #{overall_no_txns} × 0.10 EUR = %.2f EUR<br>" % (overall_no_txns * 0.10)
  src += 'Payout charges: 0.10 EUR<br>Total charges: %.2f EUR' % (overall_no_txns * 0.10 + 0.10)
  src += '<br>Net amount acquired: <b>'
  src += "%.2f" % (overall_totals.first[1] - overall_no_txns * 0.10 - 0.10)
  src += " #{overall_totals.first[0]}</b><br>"

  src += '<br><br><i>Per LC Breakdown</i>'
  totals.each do |office_name, total|
    src += "<br><b>#{office_name}</b><br>Amount acquired: "
    total.each {|currency, amount| src += "%.2f #{currency}<br>" % amount}
    src += "No. of transactions: #{no_transactions[office_name]}<br>"
    src += "Transaction charges: #{no_transactions[office_name]} × 0.10 EUR = %.2f EUR<br>" % (no_transactions[office_name] * 0.10)
    src += 'Net amount acquired: <b>'
    src += "%.2f" % (total.first[1] - no_transactions[office_name] * 0.10)
    src += " #{total.first[0]}</b><br>"
  end

  # Write 3 files
  begin
    FileUtils.mkdir_p("data/#{merchant}")
    txfile = File.new "data/#{merchant}/summary.html", 'w'
    txfile.write src
    print '.'

    CSV.open "data/#{merchant}/report.csv", 'wb' do |csv|
      # TODO: handle multiple currencies here
      puts 'WARN: Multiple currencies, only choosing first' if not overall_totals.nil? and overall_totals.length > 1

      csv << ['Office', 'Amount Acquired (EUR)', 'No. Txns', 'Txn Chrg (EUR)', 'Payout Chrg (EUR)', 'Total Chrg (EUR)', 'Net Amount Acquired (EUR)']

      csv << [assoc_list[merchant], overall_totals.first[1], overall_no_txns, '%.2f' % (overall_no_txns * 0.10), '0.10', '%.2f' % (overall_no_txns * 0.10 + 0.10), '%.2f' % (overall_totals.first[1] - (overall_no_txns * 0.10 + 0.10))]

      txns_local.each do |office_name, txn_local|
        puts 'WARN: Multiple currencies, only choosing first' if not totals[office_name].nil? and totals[office_name].length > 1

        local_no_txns = no_transactions[office_name]
        csv << [office_name, totals[office_name].first[1], local_no_txns, '%.2f' % (local_no_txns * 0.10), '0', '%.2f' % (local_no_txns * 0.10), '%.2f' % (totals[office_name].first[1]-(local_no_txns * 0.10))] unless totals[office_name].nil?
      end
    end
    print '.'

    CSV.open "data/#{merchant}/details.csv", 'wb' do |csv|
      csv << txns.first.keys
      txns.each {|txn| csv << txn.values}
    end
    print ". "
  rescue => e
    puts "Fail: #{e}."
  end

  puts 'Done.'
end