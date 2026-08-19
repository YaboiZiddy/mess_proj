# Problem Statement

## Background

Within each major barracks in the Irish Defence Forces (DF), there are three messes, one each for officers, NCOs and privates. Each mess has an appointed mess secretary, who manages accommodation, budgeting, and triaging maintenance issues. Upon speaking to several mess secretaries, difficulties in management were made apparent due to the lack of a consolidated property management solution. Because mess secretary appointments are changed on a rotational basis, the organization would benefit greatly from a standardised web app on which personnel could be trained, and in which data could be recorded both consistently and securely.

# Decision Log

## Project Scaling

Originally, the management solution would have consisted of a Python-based basic GUI where secretaries could view floor plans of their respective mess, with options to edit the occupancy state of rooms, or log maintenance tickets. The script would then automatically populate a cloud-shared spreadsheet, taking advantage of the already existing cloud solution employed within the Irish Defence Forces. This would allow secretaries and their subordinates to view the data in a more human-orientated form.

However, upon learning that this was a DF-wide problem, I chose to scale up the architecture in the form of a three tier approach:

- Presentation Tier

** The UI, consisting of a HTML rendering, capturing clicks and form input, with a periodic refresh governed in JavaScript. This tier holds no server authority.

- Application Tier

* The server process, handling authentication, authorisation, validation, organisation rules and template rendering, with Flask. This tier is the sole process that opens the database file.

- Data Tier

* The authoritative data layer, a persistent state database with constraints only, no application logic.

This way, the project would take the form of a client-server web application, without the need for installation and scoped well within the network and database architecture already present within the DF.

# Architecture


