import Foundation

// Alle tijden in de checks zijn lokale tijd; de suite draait dus in elke tijdzone.
timerChecks()
projectChecks()
multiContextChecks()
persistenceChecks()
reportChecks()
adapterChecks()

exit(Harness.summary())
