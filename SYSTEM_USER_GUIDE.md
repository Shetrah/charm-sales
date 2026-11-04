# Charm Company Hub — System User Guide

## A. System overview

**Premium Edition 2.2.0:** The refreshed interface uses Charm brand violet and teal, with role-aware mobile navigation, touch-friendly cards, compact forms and responsive layouts. The business workflows and Supabase data contracts remain the same except for the explicitly additive Contra Entry support described below.

Charm Company Hub is a React and TypeScript web application backed by Supabase. It keeps sales records, customer collections, staff activity, finance requests, company expenses and cash movements in one authenticated workspace. The interface supports English and Simplified Chinese, light and dark themes, and responsive desktop and mobile layouts.

**Sales Management** tracks customers, quotations and order documents, orders, payment submissions, verified collections, customer balances, field activity and performance. **Finance Tracking** records approved requests, confirmed disbursements, direct expenses, supplier payments, customer receipts, account balances, budgets, reconciliation and an audit history.

The systems connect through real records: a verified sales payment changes the corresponding order balance; finance can view customer collections; company disbursements enter the cashbook and expense register; Finance records actions with the acting user, reference, time and audit event.

### Workflow map

```text
Salesperson → Customer → Quotation / order document → Order
                                              ↓ Admin confirms
Customer payment → Admin verifies → Order balance and sales reporting

Requester → Finance request → Admin approval → Finance confirms payment
                                                   ↓
                      Cashbook + expense register + audit trail

Staff advance → Finance confirms disbursement → Staff submits actual expenses/refund
                                                   ↓ Finance reviews
                                      Advance balance / settlement
```

## B. Role-based guide

| Role | Access and responsibilities |
| --- | --- |
| Administrator | System-wide sales views; staff directory and role changes; order, payment and field-request review; finance request approval; Finance workspace access; team reports. |
| Salesperson | Permitted customer records, orders, payment submissions, visits and field requests; own finance requests and their status. Cannot view or change other salespeople’s records. |
| Finance Officer | Finance dashboard and registers; records approved disbursements; manages finance accounts and payees; handles reconciliation and audit. Cannot approve the finance request. Only approved requests are visible to this role. |
| Logistics Manager | Logistics workspace, orders, customers and products for fulfilment. Does not receive the sales or finance workspace. |

The current application does not define a separate Sales Manager role. Team-wide sales monitoring is available to Administrators. Sales targets are not configured; sales figures represent confirmed orders, not target attainment. Database policies and permission-checked RPC functions enforce access in addition to the interface.

## C. Sales Management workflow

1. **Customers:** Open **Customers** and choose **Create**. Add the customer’s name and contact information. Salespeople create customers under their own identity; Administrators can review team customers and assign them.
2. **Quotations:** Open **Sales operations** and prepare a quotation using the current product price book. This module helps calculate pricing; it is not itself a confirmed order.
3. **Orders:** Open **Orders**, choose **Create**, select a customer and products, and save. New orders are pending until an Administrator confirms or rejects them. Confirmed orders may proceed through fulfilment and contract documents.
4. **Payments:** After the customer has paid, open **Payments** and record the order, actual amount, reference and received date. The submission waits for Administrator verification.
5. **Balances:** Open **Balances** to see order total, verified amount paid, remaining balance and due date. Pending or rejected payments do not reduce the balance. Use the overdue filter to find late balances.
6. **Performance and reports:** The sales dashboard shows confirmed monthly sales, pending orders, active customers, outstanding balances, recent activity and a sales trend. Administrators can compare staff in **People → Team** and export reports from **Reporting** or **Reports** where available.
7. **Customer history:** Select a customer or related record to open its details. Customer history is shown through linked orders, payment records and the calculated balance, subject to the user’s access scope.

## D. Finance Tracking workflow

1. **Dashboard:** Administrators and Finance Officers open **Finance → Finance dashboard**. Choose the date range and optional staff filter. The dashboard uses saved records for pending requests, approved amounts, disbursements, staff advances, expenses, cash flow and recent requests.
2. **Submit a request:** An Administrator or salesperson opens **Requests & statements** and chooses **Request funds**. Enter the amount, category, purpose and required date. The request is submitted for Administrator review. Supplier payment requests are created by Finance users.
3. **Approval:** The Administrator reviews the request and approves, returns or rejects it. Finance approval reserves the approved amount against the configured monthly category budget.
4. **Record a disbursement:** A Finance Officer (or Administrator acting in Finance) first completes the transfer outside the portal and confirms it with the payment provider. Open the approved request and choose **Record confirmed payment**. Enter the actual amount, account, reference, date and payment proof. The portal does not transfer money.
5. **Direct company expense closeout:** A fully disbursed direct company expense closes automatically. A partial payment remains open for the remaining approved amount. No post-disbursement accountability form or extra approval is required for this direct expense workflow.
6. **Staff advances:** Staff advances continue to use **Accountability**. The staff member records actual expenses with evidence or an actual refund with a reference. Finance reviews submissions. The outstanding advance is disbursed minus accepted expenses and refunds; an unsettled advance can prevent a further advance.
7. **Registers and reports:** **Expenses** contains the consolidated expense register. Raw-material procurement is accessed separately from **Purchase** and follows Purchase Order → Goods Receipt / QC → Supplier Invoice. The Expenses screen is for general company expenditure and operating costs; use **Record other operational / financial expense** for operating costs such as utilities, rent, transport, bank charges and other non-material expenditure. **Disbursements** shows requests ready for payment, **Cashbook** shows recorded money movements, **Receipts** shows customer payment records, **Statements** supports bank/M-Pesa reconciliation, and **Audit** shows attributed finance events. Use date, staff and status filters, then export CSV or PDF where offered.

**Contra entries:** To record cash banked or money moved between company accounts, open **Finance → Contra entry → Record account transfer**. Choose the source account (where the money leaves), destination account (where it arrives), amount, date, reference and description. The system checks that the source account has sufficient balance and posts both sides together. A contra transfer changes the two account balances but is not income or expenditure. Both legs appear in the Cashbook with one reference. A reference can only be used once for a contra transfer.

Available account funds are calculated from recorded opening funds plus recorded receipts and refunds minus recorded payments, with contra transfers reducing the source and increasing the destination account. Amounts are calculated by the database; users should enter actual figures rather than calculate a balance manually. Dates use Nairobi time and finance amounts are in KES.

**One-time setup:** Contra Entry requires the additive migration `supabase/sql-editor/20261104_finance_contra_transfers.sql`. A Finance administrator should run it once in the correct Supabase project's SQL Editor before using the new tab. The migration does not delete or rewrite historical records.

## E. Step-by-step common tasks

### Create a customer and order

1. Select **Customers** in the left navigation and press **Create**.
2. Complete the customer details and save.
3. Select **Sales operations** to prepare a quotation, then open **Orders** and press **Create**.
4. Choose the customer, add products and quantities, check the calculated total and save.
5. Administrators open the pending order and choose **Confirm** or **Reject**. The decision is recorded.

### Record a customer payment

1. Open **Payments** and press **Create**.
2. Choose a confirmed order and enter the amount received, reference and date.
3. Save the submission. An Administrator verifies or rejects it.
4. Check **Balances** to see the verified amount and remaining balance.

### Review team performance (Administrator)

1. Open **People**, then select the **Team** tab.
2. Choose the period and use the search/filter controls to find a person.
3. Review confirmed sales, customer assignments and related performance information. Use the available download action for a report.

### Request funds

1. Open **Finance → Requests & statements** and press **Request funds**.
2. Enter the category, amount, purpose and required date; attach supporting information if available.
3. Save. The request appears in the approval queue for an Administrator.

### Record an approved payment (Finance Officer)

1. Open **Finance → Disbursements** and select an approved request.
2. Complete the transfer outside the portal and confirm the transaction with the payment provider.
3. Choose **Record confirmed payment**. Enter the actual amount, payment account, reference and date, attach proof, confirm the payment attestation and save.
4. Check the request detail, **Cashbook**, **Expenses** and **Audit** for the recorded transaction.

### Export a finance register

1. Open **Finance** and choose **Expenses**, **Cashbook**, **Receipts** or **Audit**.
2. Set the date range and any staff or status filter.
3. Press **CSV** or **PDF**. Narrow the filters if the export exceeds the system limit.

## F. Important system rules

- Customer balances and sales totals use confirmed orders and verified customer payments.
- The finance request approval and payment recording are separate responsibilities. Finance records payment only after an external transfer is confirmed.
- A full direct company expense closes automatically at disbursement. Its approval, amount, account, reference, proof, recorder and timestamp remain in the transaction and audit history.
- Staff advances still require accountability; accepted expenses and refunds reduce the advance balance. This process remains in place to protect staff-advance controls.
- Historical accountability entries and finance records are retained. The new closeout behavior applies when future direct company expense disbursements complete.
- A manager or salesperson cannot change another salesperson’s original records. Administrators have designated management actions. Sensitive finance operations and sales reviews are enforced in database functions and row-level security.
- The portal records transactions; it does not initiate bank or M-Pesa transfers. Contra Entry records a confirmed internal movement after the external cash deposit or transfer has happened.

## G. Mobile PWA and evidence

The app is installable as a PWA and uses a mobile-specific bottom navigation plus a slide-out menu for the full set of authorized modules. Use the menu to reach pages that are not pinned in the bottom bar. The service worker caches the application shell, not private finance, sales or staff records; creating or submitting transactions still requires a network connection.

Visit photos and general supporting documents are optional where the screen permits. Keep customer payment confirmation, payment attestations, contractual evidence, location permission for GPS check-in and production quality-control evidence where the workflow requires them.

## H. Frequently asked questions

**Why did my payment not change the customer balance?**  
It may still be pending. Only a verified payment attached to a confirmed order reduces the balance.

**Why can’t I see a customer or request?**  
Sales and personal finance records are limited by role and ownership. Ask an Administrator if the ownership or assignment needs correction.

**Does “paid” mean a money transfer was made by the portal?**  
No. A Finance Officer records a transfer after confirming it with the payment provider.

**Do direct company expenses need accountability after payment?**  
No. A fully disbursed direct company expense closes automatically. Staff advances still require accountability and review.

**Where can I find a closed transaction?**  
Open the relevant Finance register or request history and adjust the date or status filter. Closed records and their audit history are retained.

**Why can’t I see sales targets?**  
Sales targets are not configured in the current installation. The dashboard reports confirmed sales and trends.

**Where is the Sales Manager portal?**  
This installation has no Sales Manager role. Administrators have team-wide sales monitoring. A distinct read-only Sales Manager role would require coordinated frontend and database role-policy work.
