import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'dart:html' as html;
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'dart:math';

void main() {
  runApp(const RestaurantSettlementApp());
}

class RestaurantSettlementApp extends StatelessWidget {
  const RestaurantSettlementApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Restaurant Settlement Generator',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const SettlementGeneratorPage(),
    );
  }
}

class SettlementGeneratorPage extends StatefulWidget {
  const SettlementGeneratorPage({Key? key}) : super(key: key);

  @override
  _SettlementGeneratorPageState createState() => _SettlementGeneratorPageState();
}

class _SettlementGeneratorPageState extends State<SettlementGeneratorPage> {
  final TextEditingController restaurantIdController = TextEditingController();
  final TextEditingController restaurantDiscountController = TextEditingController();
  final TextEditingController sharedDeliveryFeePercentageController = TextEditingController();
  final TextEditingController settlementDateController = TextEditingController();
  final TextEditingController refundAmountController = TextEditingController();
  final TextEditingController orderValueThresholdController = TextEditingController();

  DateTimeRange? dateRange;
  DateTime settlementDate = DateTime.now();
  bool isPlatformFeesEnabled = false;
  bool isOfferEnabled = false;
  bool isNonPOSEnabled = false;

  // List to store settlement data for Excel
  final List<Map<String, dynamic>> settlementDataList = [];

  @override
  void initState() {
    super.initState();
    // Set default platform fees to enabled
    isPlatformFeesEnabled = true;

    // Set default date range to last week's Monday to Sunday
    final now = DateTime.now();
    // Go back one week
    final lastWeek = now.subtract(const Duration(days: 7));
    // Find the Monday of last week (weekday: 1 = Monday, 7 = Sunday)
    final lastWeekMonday = lastWeek.subtract(Duration(days: lastWeek.weekday - 1));
    // Find the Sunday of last week (6 days after Monday)
    final lastWeekSunday = lastWeekMonday.add(const Duration(days: 6));
    dateRange = DateTimeRange(start: lastWeekMonday, end: lastWeekSunday);

    // Initialize other controllers
    settlementDateController.text = DateFormat('dd MMM, yyyy').format(now);
    refundAmountController.text = '0';
    orderValueThresholdController.text = '199';
  }

  Future<void> _selectDateRange(BuildContext context) async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      initialDateRange: dateRange,
      firstDate: DateTime(2020),
      lastDate: DateTime(2026),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Colors.blue,
              onPrimary: Colors.white,
              surface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != dateRange) {
      setState(() {
        dateRange = picked;
      });
    }
  }

  Future<void> _selectSettlementDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: settlementDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2026),
    );
    if (picked != null && picked != settlementDate) {
      setState(() {
        settlementDate = picked;
        settlementDateController.text = DateFormat('dd MMM, yyyy').format(picked);
      });
    }
  }

  Future<List<Map<String, dynamic>>> readExcelData() async {
    final ByteData data = await rootBundle.load('assets/file/orders.xlsx');
    final Uint8List bytes = data.buffer.asUint8List();
    final excel = Excel.decodeBytes(bytes);

    final sheet = excel.tables['Orders'];
    final dataList = <Map<String, dynamic>>[];

    if (sheet != null) {
      for (var row in sheet.rows.skip(1)) {
        final status = row[1]?.value.toString().toUpperCase();
        if (status != 'CANCELLED' && status != 'REFUND_COMPLETED' && status != 'DROPPED_OFF' && status != 'ERROR' && status != 'CREATED') {
          dataList.add({
            'Order ID': row[0]?.value.toString(),
            'Status': status,
            'Restaurant ID': row[2]?.value.toString(),
            'Order Date': row[4]?.value.toString(),
            'Total Amount': row[3]?.value,
            'Items': row[5]?.value.toString(),
            'Item Totals': row[8]?.value,
            'Delivery': row[11]?.value,
            'Customer Name': row[9]?.value.toString() ?? '',
            'Customer Phone': row[10]?.value.toString() ?? '',
            'Restaurant Name': row[12]?.value.toString() ?? '',
          });
        }
      }
    } else {
      throw Exception('Sheet "Orders" not found in the Excel file.');
    }
    return dataList;
  }

  Future<void> generateSettlementPdf(
      String restaurantId,
      String restaurantName,
      List<Map<String, dynamic>> data,
      double restaurantDiscountPercentage,
      double sharedDeliveryFeePercentage,
      double orderValueThreshold,
      Uint8List topImageBytes,
      Uint8List bottomImageBytes,
      String startDateStr,
      String endDateStr,
      String settlementDateStr,
      bool isPlatformFeesEnabled,
      bool isOfferEnabled,
      bool isNonPOSEnabled,
      double refundAmount,
      ) async {
    final pdf = pw.Document();
    final topImage = pw.MemoryImage(topImageBytes);
    final bottomImage = pw.MemoryImage(bottomImageBytes);

    final filteredData = data
        .where((row) =>
    row['Restaurant ID'] == restaurantId &&
        row['Status'] != 'CANCELLED' &&
        row['Status'] != 'REFUND_COMPLETED' &&
        row['Status'] != 'DROPPED_OFF' &&
        row['Status'] != 'ERROR' &&
        row['Status'] != 'CREATED')
        .toList();

    if (filteredData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No delivered orders found.')),
      );
      return;
    }

    double itemTotal = filteredData.fold<double>(0, (sum, row) {
      final itemTotalValue = row['Item Totals'] is num
          ? row['Item Totals'] as double
          : double.tryParse(row['Item Totals']?.toString() ?? '0') ?? 0.0;
      return sum + itemTotalValue;
    });

    double restaurantDiscount = ((itemTotal * restaurantDiscountPercentage) / 100).roundToDouble();
    double discountedItemTotal = itemTotal - restaurantDiscount;
    double gst = (discountedItemTotal * 0.05).roundToDouble();
    double netBillValue = (discountedItemTotal + gst).roundToDouble();

    double paymentGatewayCharges = (netBillValue * 0.02).roundToDouble();
    double petpoojaAPICharges = isNonPOSEnabled ? 0.0 : (netBillValue * 0.01).roundToDouble();

    double platformServiceFees = 0.0;
    double deliveryAPICharges = 0.0;
    double restaurantSharedDeliveryFee = 0.0;

    if (isPlatformFeesEnabled) {
      platformServiceFees = filteredData.fold<double>(0, (sum, row) {
        double rowItemTotal = row['Item Totals'] is num
            ? row['Item Totals'] as double
            : double.tryParse(row['Item Totals']?.toString() ?? '0') ?? 0.0;
        double rowDiscount = (rowItemTotal * restaurantDiscountPercentage) / 100;
        double tax = (rowItemTotal * 0.05);
        double discountedRowTotal = rowItemTotal - rowDiscount + tax;
        return sum + (discountedRowTotal > 200 ? 20.0 : 10.0);
      });
      deliveryAPICharges = 0.0;
    } else {
      platformServiceFees = 0.0;
      deliveryAPICharges = (filteredData.length * 5).toDouble();
    }

    double totalDeliveryCharges = filteredData.fold<double>(
        0,
            (sum, row) => sum + (row['Delivery'] != null ? row['Delivery'] as double : 0.0));

    if (isOfferEnabled) {
      restaurantSharedDeliveryFee = filteredData.fold<double>(0, (sum, row) {
        double rowItemTotal = row['Item Totals'] is num
            ? row['Item Totals'] as double
            : double.tryParse(row['Item Totals']?.toString() ?? '0') ?? 0.0;
        double rowDiscount = (rowItemTotal * restaurantDiscountPercentage) / 100;
        double tax = (rowItemTotal * 0.05);
        double discountedRowTotal = rowItemTotal - rowDiscount + tax;
        double deliveryCharge = row['Delivery'] != null ? row['Delivery'] as double : 0.0;
        return sum +
            (discountedRowTotal > orderValueThreshold
                ? (deliveryCharge * 0.75).roundToDouble()
                : (deliveryCharge * sharedDeliveryFeePercentage / 100).roundToDouble());
      }).roundToDouble();
    } else {
      restaurantSharedDeliveryFee =
          ((totalDeliveryCharges * sharedDeliveryFeePercentage) / 100).roundToDouble();
    }

    double totalServiceFees = (paymentGatewayCharges +
        petpoojaAPICharges +
        deliveryAPICharges +
        platformServiceFees)
        .roundToDouble();

    double totalSettlementAmount = (netBillValue -
        totalServiceFees -
        restaurantSharedDeliveryFee -
        refundAmount)
        .roundToDouble();

    // Store settlement data for Excel
    setState(() {
      settlementDataList.add({
        'Restaurant ID': restaurantId,
        'Restaurant Name': restaurantName,
        'Total Orders': filteredData.length,
        'Settlement Amount': totalSettlementAmount,
      });
    });

    pdf.addPage(
      pw.Page(
        build: (context) => pw.Column(
          children: [
            pw.Container(
                width: double.infinity,
                child: pw.Image(topImage, fit: pw.BoxFit.fitWidth)),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Settlement Report',
                    style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('Period: $startDateStr - $endDateStr',
                        style: pw.TextStyle(fontSize: 12)),
                    pw.Text('Settlement Date: $settlementDateStr',
                        style: pw.TextStyle(fontSize: 12)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 20),
            pw.Text('BILL TO:',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text(restaurantName),
            pw.Text('Restaurant ID: $restaurantId'),
            pw.SizedBox(height: 10),
            pw.Text('Total Delivered Orders: ${filteredData.length}'),
            pw.Text('Total Settlement Amount: ${totalSettlementAmount.toStringAsFixed(2)}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 20),
            pw.Table(
              border: pw.TableBorder.all(),
              columnWidths: {
                0: const pw.FixedColumnWidth(200),
                1: const pw.FixedColumnWidth(100)
              },
              children: [
                pw.TableRow(children: [
                  pw.Text('Particular',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text('INR',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ]),
                pw.TableRow(children: [
                  pw.Text('Item Total'),
                  pw.Text(itemTotal.toStringAsFixed(2))
                ]),
                pw.TableRow(children: [
                  pw.Text('Restaurant Discounts'),
                  pw.Text(restaurantDiscount.toStringAsFixed(2))
                ]),
                pw.TableRow(children: [
                  pw.Text('Taxes (GST)'),
                  pw.Text(gst.toStringAsFixed(2))
                ]),
                pw.TableRow(children: [
                  pw.Text('Net Bill Value',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text(netBillValue.toStringAsFixed(2),
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ]),
                pw.TableRow(children: [
                  pw.Text('Platform Service Fees'),
                  pw.Text(platformServiceFees.toStringAsFixed(2)),
                ]),
                pw.TableRow(children: [
                  pw.Text('Payment Gateway Charges (2%)'),
                  pw.Text(paymentGatewayCharges.toStringAsFixed(2)),
                ]),
                if (!isNonPOSEnabled)
                  pw.TableRow(children: [
                    pw.Text('PetPooja API Charges (1%)'),
                    pw.Text(petpoojaAPICharges.toStringAsFixed(2)),
                  ]),
                pw.TableRow(children: [
                  pw.Text('Delivery API Charges'),
                  pw.Text(deliveryAPICharges.toStringAsFixed(2)),
                ]),
                pw.TableRow(children: [
                  pw.Text('Total Service Fees',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text(totalServiceFees.toStringAsFixed(2),
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ]),
                pw.TableRow(children: [
                  pw.Text('Restaurant Delivery Fee'),
                  pw.Text(restaurantSharedDeliveryFee.toStringAsFixed(2)),
                ]),
                if (refundAmount > 0)
                  pw.TableRow(children: [
                    pw.Text('Order Level Adjustments'),
                    pw.Text(refundAmount.toStringAsFixed(2)),
                  ]),
              ],
            ),
            pw.Expanded(
              child: pw.Align(
                alignment: pw.Alignment.bottomCenter,
                child: pw.Container(
                  width: double.infinity,
                  child: pw.Image(bottomImage, fit: pw.BoxFit.fitWidth),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final pdfBytes = await pdf.save();
    final blob = html.Blob([Uint8List.fromList(pdfBytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final safeRestaurantName = (restaurantName.isNotEmpty
        ? restaurantName
        : 'NA')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final safeStartDate = startDateStr.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final safeEndDate = endDateStr.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final anchor = html.AnchorElement(href: url)
      ..target = 'blank'
      ..download =
          '${safeRestaurantName}_${restaurantId}_${safeStartDate}_to_${safeEndDate}_settlement.pdf';
    anchor.click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> generateCombinedExcel() async {
    final excel = Excel.createExcel();
    final sheet = excel['SettlementSummary'];

    // Add headers
    sheet.appendRow([
      'Restaurant ID',
      'Restaurant Name',
      'Total Orders',
      'Settlement Amount (INR)',
    ]);

    // Add data rows
    for (var data in settlementDataList) {
      sheet.appendRow([
        data['Restaurant ID']?.toString() ?? '',
        data['Restaurant Name']?.toString() ?? '',
        data['Total Orders'] as int,
        data['Settlement Amount'] as double,
      ]);
    }

    // Generate Excel file
    final excelBytes = excel.encode();
    if (excelBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error generating Excel file.')),
      );
      return;
    }

    // Download Excel file
    final blob = html.Blob([Uint8List.fromList(excelBytes)]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..target = 'blank'
      ..download = 'combined_settlement_report_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
    anchor.click();
    html.Url.revokeObjectUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Restaurant Settlement Generator')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: restaurantIdController,
                decoration: const InputDecoration(labelText: 'Enter Restaurant ID'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: restaurantDiscountController,
                decoration: const InputDecoration(labelText: 'Enter Restaurant Discount Percentage'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: sharedDeliveryFeePercentageController,
                decoration: const InputDecoration(labelText: 'Enter Shared Delivery Fee Percentage'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              if (isOfferEnabled)
                TextField(
                  controller: orderValueThresholdController,
                  decoration: const InputDecoration(labelText: 'Enter Order Value Threshold'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: refundAmountController,
                decoration: const InputDecoration(labelText: 'Enter Refund Amount'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Checkbox(
                    value: isPlatformFeesEnabled,
                    onChanged: (value) {
                      setState(() {
                        isPlatformFeesEnabled = value ?? false;
                      });
                    },
                  ),
                  const Text('Include Platform Fees'),
                ],
              ),
              Row(
                children: [
                  Checkbox(
                    value: isOfferEnabled,
                    onChanged: (value) {
                      setState(() {
                        isOfferEnabled = value ?? false;
                      });
                    },
                  ),
                  const Text('Enable Offer'),
                ],
              ),
              Row(
                children: [
                  Checkbox(
                    value: isNonPOSEnabled,
                    onChanged: (value) {
                      setState(() {
                        isNonPOSEnabled = value ?? false;
                      });
                    },
                  ),
                  const Text('Non-POS'),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      dateRange == null
                          ? 'Select Date Range'
                          : 'Period: ${DateFormat('dd MMM').format(dateRange!.start)} - ${DateFormat('dd MMM').format(dateRange!.end)}',
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => _selectDateRange(context),
                    child: const Text('Pick Date Range'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: settlementDateController,
                decoration: InputDecoration(
                  labelText: 'Settlement Date',
                  hintText: 'Click to change date',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () => _selectSettlementDate(context),
                  ),
                ),
                readOnly: true,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  final restaurantId = restaurantIdController.text;
                  final restaurantDiscountPercentage =
                      double.tryParse(restaurantDiscountController.text) ?? 0.0;
                  final sharedDeliveryFeePercentage =
                      double.tryParse(sharedDeliveryFeePercentageController.text) ?? 0.0;
                  final orderValueThreshold =
                  isOfferEnabled ? (double.tryParse(orderValueThresholdController.text) ?? 199.0) : 0.0;
                  final refundAmount =
                      double.tryParse(refundAmountController.text) ?? 0.0;
                  final startDateStr = dateRange != null
                      ? DateFormat('dd MMM').format(dateRange!.start)
                      : '';
                  final endDateStr = dateRange != null
                      ? DateFormat('dd MMM').format(dateRange!.end)
                      : '';
                  final settlementDateStr = settlementDateController.text;

                  Uint8List topImageBytes = await rootBundle
                      .load('assets/file/top.png')
                      .then((data) => data.buffer.asUint8List());
                  Uint8List bottomImageBytes = await rootBundle
                      .load('assets/file/bottom.png')
                      .then((data) => data.buffer.asUint8List());

                  if (restaurantId.isNotEmpty && dateRange != null) {
                    try {
                      final data = await readExcelData();
                      final restaurantName = data
                          .firstWhereOrNull((row) => row['Restaurant ID'] == restaurantId)
                      ?['Restaurant Name']
                          ?.toString() ??
                          '';
                      await generateSettlementPdf(
                        restaurantId,
                        restaurantName,
                        data,
                        restaurantDiscountPercentage,
                        sharedDeliveryFeePercentage,
                        orderValueThreshold,
                        topImageBytes,
                        bottomImageBytes,
                        startDateStr,
                        endDateStr,
                        settlementDateStr,
                        isPlatformFeesEnabled,
                        isOfferEnabled,
                        isNonPOSEnabled,
                        refundAmount,
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please fill all required fields.')));
                  }
                },
                child: const Text('Generate Settlement'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: settlementDataList.isEmpty
                    ? null
                    : () async {
                  await generateCombinedExcel();
                },
                child: const Text('Download Combined Excel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}