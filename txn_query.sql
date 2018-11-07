SELECT
  tx.id                              "TXN ID",
  tx.created_at                      "TXN Date",
  tx.psp_reference                   "PSP Reference",
  tx.payment_method                  "Method",
  tx.status                          "Payment Status",
  tx.additional_details              "Details",
  oa.id                              "App ID",
  o.id                               "Opp Id",
  o.title                            "Opp Title",
  host_lc.name                       "Host LC",
  host_mc.name                       "Host MC",
  host_rg.name                       "Host Rgn",
  oa.person_id                       "Person ID",
  p.first_name || ' ' || p.last_name "Person Name",
  home_lc.name                       "Home LC",
  home_mc.name                       "Home MC",
  home_rg.name                       "Home RG"
FROM transactions tx
  JOIN opportunity_applications oa
    ON tx.opportunity_application_id = oa.id
  JOIN people p
    ON oa.person_id = p.id
  JOIN opportunities o
    ON oa.opportunity_id = o.id
  JOIN offices home_lc
    ON p.home_lc_id = home_lc.id
  JOIN offices home_mc
    ON home_lc.parent_id = home_mc.id
  JOIN offices home_rg
    ON home_mc.parent_id = home_rg.id
  JOIN offices host_lc
    ON o.host_lc_id = host_lc.id
  JOIN offices host_mc
    ON host_lc.parent_id = host_mc.id
  JOIN offices host_rg
    ON host_mc.parent_id = host_rg.id
WHERE psp_reference IS NOT NULL
AND tx.created_at >= '2018-04-20'