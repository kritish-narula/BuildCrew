/// Fixed demo credentials (demo mode only). OTP is always 123456.
/// (phone, trade key, name, role): one worker per trade, a contractor (customer account with a business
/// name) and a homeowner. The role is `customer`, `contractor` or `worker`.
const demoAccounts = [
  ('9100000001', 'customer', 'Priya Sharma', 'customer'),
  ('9100000002', 'contractor', 'Anil Deshmukh', 'contractor'),
  ('9200000001', 'mason', 'Ramesh Pawar', 'worker'),
  ('9200000003', 'plumber', 'Imran Shaikh', 'worker'),
  ('9200000005', 'electrician', 'Venkat Rao', 'worker'),
  ('9200000007', 'carpenter', 'Harpreet Singh', 'worker'),
  ('9200000009', 'painter', 'Selvam K', 'worker'),
  ('9200000021', 'helper', 'Manoj Mahto', 'worker'),
];

/// Icon + colour + label for a demo account chip (customers and contractors have no trade).
bool isDemoCustomerRole(String role) => role == 'customer' || role == 'contractor';
