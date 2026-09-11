import Foundation

// All times in the checks are local time; the suite therefore runs in any time zone.
timerChecks()
projectChecks()
multiContextChecks()
breakChecks()
rateChecks()
persistenceChecks()
reportChecks()
adapterChecks()
versionChecks()
invoiceChecks()
smtpChecks()

exit(Harness.summary())
