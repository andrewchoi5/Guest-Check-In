

import UIKit

class MealTableViewController: UITableViewController,
        CDTHTTPInterceptor, CDTReplicatorDelegate {
    // MARK: Properties
    
    var meals = [Meal]()
    var datastoreManager: CDTDatastoreManager?
    var datastore: CDTDatastore?
    
    // Define two sync directions: push and pull.
    // .Push will copy local data from FoodTracker to Cloudant.
    // .Pull will copy remote data from Cloudant to FoodTracker.
    enum SyncDirection {
        case Push
        case Pull
    }
    
    // Track pending .Push and .Pull replications here.
    var replications = [SyncDirection: CDTReplicator]()
    
    // MARK: Cloudant Settings
    
    let userAgent = "FoodTracker"
    let cloudantDBName = "food_tracker"
    
    // NOTE: You must change these values for your own application.
    let cloudantAccount = "bdc14166-5d69-4cf7-a627-549d773960f1-bluemix"
    let cloudantApiKey = "andownwaterminedsteakeds"
    let cloudantApiPassword = "5138e7bca44b334a39652dfc7f685694814c25d9"

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Activate the pull-to-refresh control.
        self.refreshControl = UIRefreshControl()
        self.refreshControl?.addTarget(self, action:
            #selector(MealTableViewController.handleRefresh(_:)),
                                       forControlEvents: UIControlEvents.ValueChanged)
        
        // Use the edit button item provided by the table view controller.
        navigationItem.leftBarButtonItem = editButtonItem()
        
        // Initialize the Cloudant Sync local datastore.
        initDatastore()
        
        
        // Immediately pull changes from Cloudant.
        sync(.Pull)
    }
 
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    // MARK: - Table view data source

    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return meals.count
    }

    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        // Table view cells are reused and should be dequeued using a cell identifier.
        let cellIdentifier = "MealTableViewCell"
        let cell = tableView.dequeueReusableCellWithIdentifier(cellIdentifier, forIndexPath: indexPath) as! MealTableViewCell
        
        // Fetches the appropriate meal for the data source layout.
        let meal = meals[indexPath.row]
        
        cell.nameLabel.text = meal.name
        cell.photoImageView.image = meal.photo
        cell.ratingControl.rating = meal.rating
        
        return cell
    }

    // Override to support conditional editing of the table view.
    override func tableView(tableView: UITableView, canEditRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        // Return false if you do not want the specified item to be editable.
        return true
    }
    

    // Override to support editing the table view.
    override func tableView(tableView: UITableView, commitEditingStyle editingStyle: UITableViewCellEditingStyle, forRowAtIndexPath indexPath: NSIndexPath) {
        if editingStyle == .Delete {
            // Delete the row from the data source
            let meal = meals[indexPath.row]
            deleteMeal(meal)
            meals.removeAtIndex(indexPath.row)
            tableView.deleteRowsAtIndexPaths([indexPath], withRowAnimation: .Fade)
            
            // Push this deletion to Cloudant.
            sync(.Push)
        } else if editingStyle == .Insert {
            // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
        }    
    }


    /*
    // Override to support rearranging the table view.
    override func tableView(tableView: UITableView, moveRowAtIndexPath fromIndexPath: NSIndexPath, toIndexPath: NSIndexPath) {

    }
    */

    /*
    // Override to support conditional rearranging of the table view.
    override func tableView(tableView: UITableView, canMoveRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        // Return false if you do not want the item to be re-orderable.
        return true
    }
    */

    
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        if segue.identifier == "ShowDetail" {
            let mealDetailViewController = segue.destinationViewController as! MealViewController
            
            // Get the cell that generated this segue.
            if let selectedMealCell = sender as? MealTableViewCell {
                let indexPath = tableView.indexPathForCell(selectedMealCell)!
                let selectedMeal = meals[indexPath.row]
                mealDetailViewController.meal = selectedMeal
            }
        }
        else if segue.identifier == "AddItem" {
            print("Adding new meal.")
        }
    }
    

    @IBAction func unwindToMealList(sender: UIStoryboardSegue) {
        if let sourceViewController = sender.sourceViewController as? MealViewController, meal = sourceViewController.meal {
            if let selectedIndexPath = tableView.indexPathForSelectedRow {
                // Update an existing meal.
                meals[selectedIndexPath.row] = meal
                tableView.reloadRowsAtIndexPaths([selectedIndexPath], withRowAnimation: .None)
                updateMeal(meal)
                
                // Mark the meal in-flight. When sync completes, the
                // indicator will stop.
                let cell = tableView.cellForRowAtIndexPath(selectedIndexPath)
                    as! MealTableViewCell
                cell.syncIndicator.startAnimating()
                
            } else {
                // Add a new meal.
                let newIndexPath = NSIndexPath(forRow: meals.count, inSection: 0)
                meals.append(meal)
                tableView.insertRowsAtIndexPaths([newIndexPath], withRowAnimation: .Bottom)
                createMeal(meal)
                
                // Mark the meal in-flight. When sync completes, the
                // indicator will stop.
                let cell = tableView.cellForRowAtIndexPath(newIndexPath)
                    as! MealTableViewCell
                cell.syncIndicator.startAnimating()
                
                
            }
            
            // Push this edit or creation to Cloudant.
            sync(.Push)
        }
    }
    
    // MARK: Datastore
    
    func initDatastore() {
        let fileManager = NSFileManager.defaultManager()
        
        let documentsDir = fileManager.URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask).last!
        
        let storeURL = documentsDir.URLByAppendingPathComponent("foodtracker-meals")
        let path = storeURL.path
        
        do {
            datastoreManager = try CDTDatastoreManager(directory: path)
            datastore = try datastoreManager!.datastoreNamed("meals")
        } catch {
            fatalError("Failed to initialize datastore: \(error)")
        }
        
        storeSampleMeals()
        datastore?.ensureIndexed(["created_at"], withName: "timestamps")
        
        // Everything is ready. Load all meals from the datastore.
        loadMealsFromDatastore()
        
        // Immediately pull changes from Cloudant.
        sync(.Pull)
    }
    
    func populateRevision(meal: Meal, revision: CDTDocumentRevision?) {
        // Populate a document revision from a Meal.
        let rev: CDTDocumentRevision = revision ?? CDTDocumentRevision(docId: meal.docId)
        rev.body["name"] = meal.name
        rev.body["rating"] = meal.rating
        
        // Set created_at as an ISO 8601-formatted string.
        let dateFormatter = NSDateFormatter()
        dateFormatter.locale = NSLocale(localeIdentifier: "en_US_POSIX")
        dateFormatter.timeZone = NSTimeZone(abbreviation: "GMT")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        rev.body["created_at"] = dateFormatter.stringFromDate(meal.createdAt)
        
        if let data = UIImagePNGRepresentation(meal.photo!) {
            let attachment = CDTUnsavedDataAttachment(data: data, name: "photo.jpg", type: "image/jpg")
            rev.attachments[attachment.name] = attachment
        }
    }
    
    func createMeal(meal: Meal) -> Bool {
        // User-created meals will have docId == nil. Sample meals have a string docId.
        // For sample meals, look up the existing doc, with three possible outcomes:
        //   1. No exception; the doc is already present. Do nothing.
        //   2. The doc has already been created, then deleted. Do nothing.
        //   3. The doc has never been created. Create it.
        if let docId = meal.docId {
            do {
                try datastore!.getDocumentWithId(docId)
                print("Skip \(docId) creation: already exists")
                return false
            } catch let error as NSError {
                if (error.userInfo["NSLocalizedFailureReason"] as? String != "not_found") {
                    print("Skip \(docId) creation: already deleted by user")
                    return false
                }
                
                print("Create sample meal: \(docId)")
            }
        }
        
        let rev = CDTDocumentRevision(docId: meal.docId)
        populateRevision(meal, revision: rev)
        
        do {
            let result = try datastore!.createDocumentFromRevision(rev)
            print("Created \(result.docId) \(result.revId)")
            
            // Remember the new ID assigned by the datastore.
            meal.docId = result.docId
        } catch {
            print("Error creating meal: \(error)")
        }
        
        return true
    }
    
    func deleteMeal(meal: Meal) {
        updateMeal(meal, isDelete: true)
    }
    
    func updateMeal(meal: Meal) {
        updateMeal(meal, isDelete: false)
    }
    
    func updateMeal(meal: Meal, isDelete: Bool) {
        guard let docId = meal.docId else {
            print("Cannot update a meal with no document ID")
            return
        }
        
        let label = isDelete ? "Delete" : "Update"
        print("\(label) \(docId): begin")
        
        // First, fetch the current document revision from the DB.
        var rev: CDTDocumentRevision
        do {
            rev = try datastore!.getDocumentWithId(docId)
            populateRevision(meal, revision: rev)
        } catch {
            print("Error loading meal \(docId): \(error)")
            return
        }
        
        do {
            var result: CDTDocumentRevision
            if (isDelete) {
                result = try datastore!.deleteDocumentFromRevision(rev)
            } else {
                result = try datastore!.updateDocumentFromRevision(rev)
            }
            
            print("\(label) \(docId) ok: \(result.revId)")
        } catch {
            print("Error updating \(docId): \(error)")
            return
        }
    }
    
    func loadMealsFromDatastore() {
        let query = ["created_at": ["$gt":""]]
        let result = datastore?.find(query, skip: 0, limit: 0, fields: nil, sort: [["created_at":"asc"]])
        guard result != nil else {
            print("Failed to query for meals")
            return
        }
        
        meals.removeAll()
        result!.enumerateObjectsUsingBlock({ (doc, idx, stop) -> Void in
            if let meal = Meal(aDoc: doc) {
                self.meals.append(meal)
            }
        })
    }
    
    func storeSampleMeals() {
        let photo1 = UIImage(named: "meal1")
        let photo2 = UIImage(named: "meal2")
        let photo3 = UIImage(named: "meal3")
        
        let meal1 = Meal(name: "Caprese Salad", photo: photo1, rating: 4, docId: "sample-1")!
        let meal2 = Meal(name: "Chicken and Potatoes", photo: photo2, rating: 5, docId: "sample-2")!
        let meal3 = Meal(name: "Pasta with Meatballs", photo: photo3, rating: 3, docId: "sample-3")!
        
        // Hard code the createdAt property to get a consistent revision ID. That way, devices that share
        // a common cloud database will not generate conflicts as they sync their own sample meals.
        let comps = NSDateComponents()
        comps.day = 1
        comps.month = 1
        comps.year = 2016
        comps.timeZone = NSTimeZone(abbreviation: "GMT")
        let newYear = NSCalendar.currentCalendar().dateFromComponents(comps)!
        
        meal1.createdAt = newYear
        meal2.createdAt = newYear
        meal3.createdAt = newYear
        
        let created1 = createMeal(meal1)
        let created2 = createMeal(meal2)
        let created3 = createMeal(meal3)
        
        if (created1 || created2 || created3) {
            print("Sample meals changed; begin push sync")
            sync(.Push)
        }
    }
    
    // MARK: Cloudant Sync
    
    // Intercept HTTP requests and set the User-Agent header.
    func interceptRequestInContext(context: CDTHTTPInterceptorContext)
        -> CDTHTTPInterceptorContext {
            let info = NSBundle.mainBundle().infoDictionary!
            let appVer = info["CFBundleShortVersionString"]
            let osVer = NSProcessInfo().operatingSystemVersionString
            let ua = "\(userAgent)/\(appVer) (iOS \(osVer)"
            
            context.request.setValue(ua, forHTTPHeaderField: "User-Agent")
            return context
    }
    
    func handleRefresh(refreshControl: UIRefreshControl) {
        print("Pull to refresh!")
        sync(.Pull)
    }
    
    // Return an NSURL to the database, with authentication.
    func cloudURL() -> NSURL {
        let credentials = "\(cloudantApiKey):\(cloudantApiPassword)"
        let host = "\(cloudantAccount).cloudant.com"
        let url = "https://\(credentials)@\(host)/\(cloudantDBName)"
        
        return NSURL(string: url)!
    }
    
    // Push or pull local data to or from the central cloud.
    func sync(direction: SyncDirection) {
        let existingReplication = replications[direction]
        guard existingReplication == nil else {
            print("Ignore \(direction) replication; already running")
            return
        }
        
        let factory = CDTReplicatorFactory(
            datastoreManager: datastoreManager)
        
        let job = (direction == .Push)
            ? CDTPushReplication(source: datastore!, target: cloudURL())
            : CDTPullReplication(source: cloudURL(), target: datastore!)
        job.addInterceptor(self)
        
        do {
            // Ready: Create the replication job.
            replications[direction] = try factory.oneWay(job)
            
            // Set: Assign myself as the replication delegate.
            replications[direction]!.delegate = self
            
            // Go!
            try replications[direction]!.start()
        } catch {
            print("Error initializing \(direction) sync: \(error)")
            return
        }
        
        print("Started \(direction) sync: \(replications[direction])")
    }
    
    func replicatorDidChangeState(replicator: CDTReplicator!) {
        // The new state is in replicator.state.
    }
    
    func replicatorDidChangeProgress(replicator: CDTReplicator!) {
        // See replicator.changesProcessed and replicator.changesTotal
        // for progress data.
    }
    
    func replicatorDidComplete(replicator: CDTReplicator!) {
        print("Replication complete \(replicator)")
        
        if (replicator == replications[.Pull]) {
            if (replicator.changesProcessed > 0) {
                // Reload the meals, and refresh the UI.
                loadMealsFromDatastore()
                dispatch_async(dispatch_get_main_queue(), {
                    self.tableView.reloadData()
                })
            }
            
            // End the refresh spinner, if necessary.
            self.refreshControl?.endRefreshing()
        }
        else if (replicator == replications[.Push]) {
                // Stop all active spinners. Note, this does not perfectly
                // reflect the real replication state; however, it is very
                // simple, and it typically works well enough.
            dispatch_async(dispatch_get_main_queue(), {
                for cell in self.tableView.visibleCells as! [MealTableViewCell] {
                    cell.syncIndicator.stopAnimating()
                }
            })
        }
    
        clearReplicator(replicator)
    }
    
    func replicatorDidError(replicator: CDTReplicator!, info:NSError!) {
        print("Replicator error \(replicator) \(info)")
        clearReplicator(replicator)
    }
    
    func clearReplicator(replicator: CDTReplicator!) {
        // Determine the replication direction, given the replicator
        // argument.
        let direction = (replicator == replications[.Push])
            ? SyncDirection.Push
            : SyncDirection.Pull
        
        print("Clear replication: \(direction)")
        replications[direction] = nil
    }
}
