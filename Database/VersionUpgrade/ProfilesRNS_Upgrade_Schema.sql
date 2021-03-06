/*
Run this script on:

        Profiles 1.0.2    -  This database will be modified

to synchronize it with:

        Profiles 1.0.3

You are recommended to back up your database before running this script
*/
SET NUMERIC_ROUNDABORT OFF
GO
SET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
IF EXISTS (SELECT * FROM tempdb..sysobjects WHERE id=OBJECT_ID('tempdb..#tmpErrors')) DROP TABLE #tmpErrors
GO
CREATE TABLE #tmpErrors (Error int)
GO
SET XACT_ABORT ON
GO
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
GO
BEGIN TRANSACTION
GO
PRINT N'Creating schemata'
GO
CREATE SCHEMA [History.Framework]
AUTHORIZATION [dbo]
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
CREATE SCHEMA [History]
AUTHORIZATION [dbo]
GO
PRINT N'Altering [Profile.Data].[vwPerson.Photo]'
GO
ALTER VIEW [Profile.Data].[vwPerson.Photo]
AS
SELECT p.*, m.NodeID PersonNodeID, v.NodeID UserNodeID, o.Value+'Modules/CustomViewPersonGeneralInfo/PhotoHandler.ashx?NodeID='+CAST(m.NodeID as varchar(50)) URI
FROM [Profile.Data].[Person.Photo] p
	INNER JOIN [RDF.Stage].[InternalNodeMap] m
		ON m.Class = 'http://xmlns.com/foaf/0.1/Person'
			AND m.InternalType = 'Person'
			AND m.InternalID = CAST(p.PersonID as varchar(50))
	INNER JOIN [User.Account].[User] u
		ON p.PersonID = u.PersonID
	INNER JOIN [RDF.Stage].[InternalNodeMap] v
		ON v.Class = 'http://profiles.catalyst.harvard.edu/ontology/prns#User'
			AND v.InternalType = 'User'
			AND v.InternalID = CAST(u.UserID as varchar(50))
	INNER JOIN [Framework.].[Parameter] o
		ON o.ParameterID = 'baseURI';
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.Entity.InformationResource]'
GO
ALTER TABLE [Profile.Data].[Publication.Entity.InformationResource] ALTER COLUMN [URL] [varchar] (2000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Refreshing [Profile.Data].[vwPublication.Entity.InformationResource]'
GO
EXEC sp_refreshview N'[Profile.Data].[vwPublication.Entity.InformationResource]'
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [RDF.].[vwBigDataTriple]'
GO
CREATE VIEW [RDF.].[vwBigDataTriple] AS
SELECT    
'<' + s.VALUE + '> ' + 
'<' + p.value + '> ' + 
CASE WHEN o.objecttype = 1 THEN  REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(o.VALUE,'\','\\'),'"','\"'),CHAR(10),'\n'),CHAR(13),'\r'),CHAR(9),'\t')    
	 else '<'  + o.value + '>' end
+ ' .' + CHAR(13) + CHAR(10) triple
FROM [RDF.].Triple t, [RDF.].Node s, [RDF.].Node p, [RDF.].Node o
WHERE t.subject=s.nodeid AND t.predicate=p.nodeid AND t.object=o.nodeid
AND s.ViewSecurityGroup  =-1 AND  p.ViewSecurityGroup =-1  and o.ViewSecurityGroup =-1 AND t.ViewSecurityGroup =-1
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Framework.].[RunJobGroup]'
GO
ALTER PROCEDURE [Framework.].[RunJobGroup]
	@JobGroup INT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	-- Exit if there is an error
	IF EXISTS (SELECT * FROM [Framework.].[Job] WHERE IsActive = 1 AND Status = 'ERROR')
	BEGIN
		RETURN
	END
	
	CREATE TABLE #Job (
		Step INT IDENTITY(0,1) PRIMARY KEY,
		JobID INT,
		Script NVARCHAR(MAX)
	)
	
	-- Get the list of job steps
	INSERT INTO #Job (JobID, Script)
		SELECT JobID, Script
			FROM [Framework.].[Job]
			WHERE JobGroup = @JobGroup AND IsActive = 1
			ORDER BY Step, JobID

	DECLARE @Step INT
	DECLARE @SQL NVARCHAR(MAX)
	DECLARE @LogID INT
	DECLARE @JobStart DATETIME
	DECLARE @JobEnd DATETIME
	DECLARE @JobID INT
	DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
	DECLARE @date DATETIME,@auditid UNIQUEIDENTIFIER, @rows INT
	SELECT @date=GETDATE() 
	
	-- Loop through all steps
	WHILE EXISTS (SELECT * FROM #Job)
	BEGIN
		-- Get the next step
		SELECT @Step = (SELECT MIN(Step) FROM #Job)
		
		-- Get the SQL
		SELECT @SQL = Script, @JobID = JobID
			FROM #Job
			WHERE Step = @Step

		-- Wait until other jobs are complete
		WHILE EXISTS (SELECT *
						FROM [Framework.].[Job] o, #Job j
						WHERE o.JobID = j.JobID AND o.Status = 'PROCESSING')
		BEGIN
			WAITFOR DELAY '00:00:30'
		END

		-- Update the status
		SELECT @JobStart = GetDate()
		UPDATE o
			SET o.Status = 'PROCESSING', o.LastStart = @JobStart, o.LastEnd = NULL, o.ErrorCode = NULL, o.ErrorMsg = NULL
			FROM [Framework.].[Job] o, #Job j
			WHERE o.JobID = j.JobID AND j.Step = @Step
		INSERT INTO [Framework.].[Log.Job] (JobID, JobGroup, Step, Script, JobStart, Status)
			SELECT @JobID, @JobGroup, @Step, @SQL, @JobStart, 'PROCESSING'
		SELECT @LogID = @@IDENTITY
			
		
		-- Log Step Execution
		--SELECT @date=GETDATE()
		--EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@SQL,@ProcessStartDate=@date,@insert_new_record=1
		
		BEGIN TRY 
			-- Run the step
			EXEC sp_executesql @SQL
		END TRY 
		BEGIN CATCH
			--Check success
			IF @@TRANCOUNT > 0
				ROLLBACK
				
			--SELECT @date=GETDATE()
			--EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@SQL,@ProcessEndDate=@date,@error = 1,@insert_new_record=0
			-- Log error 
			-- Update the status
			SELECT @JobEnd = GetDate()
			SELECT @ErrMsg = ERROR_MESSAGE(), @ErrSeverity = ERROR_SEVERITY()
			UPDATE o
				SET o.Status = 'JOB FAILED', o.LastEnd = GetDate(), o.ErrorCode = @ErrSeverity, o.ErrorMsg = @ErrMsg
				FROM [Framework.].[Job] o, #Job j
				WHERE o.JobID = j.JobID AND j.Step = @Step
			UPDATE [Framework.].[Log.Job]
				SET JobEnd = @JobEnd, Status = 'JOB FAILED', ErrorCode = @ErrSeverity, ErrorMsg = @ErrMsg
				WHERE LogID = @LogID
			--Raise an error with the details of the exception

			RAISERROR(@ErrMsg, @ErrSeverity, 1)
			RETURN
		END CATCH
		
		-- Log Step Execution
		--SELECT @date=GETDATE()
		--EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@SQL,@ProcessStartDate=@date,@insert_new_record=0
		
		
		-- Update the status
		SELECT @JobEnd = GetDate()
		UPDATE o
			SET o.Status = 'COMPLETED', o.LastEnd = GetDate(), o.ErrorCode = NULL, o.ErrorMsg = NULL
			FROM [Framework.].[Job] o, #Job j
			WHERE o.JobID = j.JobID AND j.Step = @Step
		UPDATE [Framework.].[Log.Job]
			SET JobEnd = @JobEnd, Status = 'COMPLETED'
			WHERE LogID = @LogID

		-- Remove the first step from the list
		DELETE j
			FROM #Job j
			WHERE Step = @Step
	END

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Module].[Support.GetHTML]'
GO
ALTER PROCEDURE [Profile.Module].[Support.GetHTML]
	@NodeID BIGINT,
	@EditMode BIT = 0
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @str VARCHAR(MAX)

	DECLARE @PersonID INT
 	SELECT @PersonID = CAST(m.InternalID AS INT)
		FROM [RDF.Stage].[InternalNodeMap] m, [RDF.].Node n
		WHERE m.Status = 3 AND m.ValueHash = n.ValueHash AND n.NodeID = @NodeID
			AND m.Class = 'http://xmlns.com/foaf/0.1/Person' AND m.InternalType = 'Person'

	IF @PersonID IS NOT NULL
	BEGIN

		if @editMode = 0
			set @str = 'Local representatives can answer questions about the Profiles website or help with editing a profile or issues with profile data. For assistance with this profile:'
		else
			set @str = 'Local representatives can help you modify your basic information above, including title and contact information, or answer general questions about Profiles. For assistance with this profile:'

		select @str = @str + (
				select ' '+s.html
					from [Profile.Module].[Support.HTML] s, (
						select m.SupportID, min(SortOrder) x 
							from [Profile.Cache].[Person.Affiliation] a, [Profile.Module].[Support.Map] m
							where a.instititutionname = m.institution and (a.departmentname = m.department or m.department = '')
								and a.PersonID = @PersonID
							group by m.SupportID
					) t
					where s.SupportID = t.SupportID
					order by t.x
					for xml path(''), type
			).value('(./text())[1]','nvarchar(max)')

	END

	SELECT @str HTML WHERE @str IS NOT NULL

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.DeleteOnePublication]'
GO
ALTER procedure [Profile.Data].[Publication.DeleteOnePublication]
	@PersonID INT,
	@PubID varchar(50)
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
BEGIN TRY 	 
	BEGIN TRANSACTION

		if exists (select * from [Profile.Data].[Publication.Person.Include]  where pubid = @PubID and PersonID = @PersonID)
		begin

			declare @pmid int
			declare @mpid varchar(50)

			set @pmid = (select pmid from [Profile.Data].[Publication.Person.Include] where pubid = @PubID)
			set @mpid = (select mpid from [Profile.Data].[Publication.Person.Include] where pubid = @PubID)

			insert into [Profile.Data].[Publication.Person.Exclude](pubid,PersonID,pmid,mpid)
				values (@pubid,@PersonID,@pmid,@mpid)

			delete from [Profile.Data].[Publication.Person.Include] where pubid = @PubID
			delete from [Profile.Data].[Publication.Person.Add] where pubid = @PubID

			if @pmid is not null
				delete from [Profile.Cache].[Publication.PubMed.AuthorPosition] where personid = @PersonID and pmid = @pmid

			if @pmid is not null
				delete from [Profile.Data].[Publication.PubMed.Disambiguation] where personid = @PersonID and pmid = @pmid 
				
		end

	COMMIT TRANSACTION
	END TRY
	BEGIN CATCH
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
 
		-- Raise an error with the details of the exception
		SELECT @ErrMsg =  ERROR_MESSAGE(),
					 @ErrSeverity = ERROR_SEVERITY()
 
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
			 
	END CATCH		

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Person.GetFacultyRanks]'
GO
ALTER procedure [Profile.Data].[Person.GetFacultyRanks]
	-- Add the parameters for the stored procedure here

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	SELECT x.FacultyRankID, x.FacultyRank,  n.NodeID, n.Value URI
		FROM (
				SELECT CAST(MAX(FacultyRankID) AS VARCHAR(50)) FacultyRankID,
						LTRIM(RTRIM(FacultyRank)) FacultyRank					
				FROM [Profile.Data].[Person.FacultyRank] WITH (NOLOCK) where facultyrank <> ''				
				group by FacultyRank ,FacultyRankSort
			) x 
			LEFT OUTER JOIN [RDF.Stage].InternalNodeMap m WITH (NOLOCK)
				ON m.class = 'http://profiles.catalyst.harvard.edu/ontology/prns#FacultyRank'
					AND m.InternalType = 'FacultyRank'
					AND m.InternalID = CAST(x.FacultyRankID AS VARCHAR(50))
			LEFT OUTER JOIN [RDF.].Node n WITH (NOLOCK)
				ON m.NodeID = n.NodeID
					AND n.ViewSecurityGroup = -1
		
 
 



END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.PubMed.GetAllPMIDs]'
GO
-- Stored Procedure

ALTER procedure [Profile.Data].[Publication.PubMed.GetAllPMIDs] (@GetOnlyNewXML BIT=0 )
AS
BEGIN
	SET NOCOUNT ON;	


	BEGIN TRY
		IF @GetOnlyNewXML = 1 
		-- ONLY GET XML FOR NEW Publications
			BEGIN
				SELECT pmid
				  FROM [Profile.Data].[Publication.PubMed.Disambiguation]
				 WHERE pmid NOT IN(SELECT PMID FROM [Profile.Data].[Publication.PubMed.General])
				   AND pmid IS NOT NULL 
			END
		ELSE 
		-- FULL REFRESH
			BEGIN
				SELECT pmid
				  FROM [Profile.Data].[Publication.PubMed.Disambiguation]
				 WHERE pmid IS NOT NULL 
				 UNION   
				SELECT pmid
				  FROM [Profile.Data].[Publication.Person.Include]
				 WHERE pmid IS NOT NULL 
			END 

	END TRY
	BEGIN CATCH
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK

		-- Raise an error with the details of the exception
		SELECT @ErrMsg = 'FAILED WITH : ' + ERROR_MESSAGE(),
					 @ErrSeverity = ERROR_SEVERITY()

		RAISERROR(@ErrMsg, @ErrSeverity, 1)

	END CATCH				
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Search.Cache].[Private.UpdateCache]'
GO
ALTER PROCEDURE [Search.Cache].[Private.UpdateCache]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	--------------------------------------------------
	-- Prepare lookup tables
	--------------------------------------------------

	-- Get a list of valid nodes
	create table #Node (
		NodeID bigint primary key
	)
	insert into #Node 
		select NodeID 
		from [RDF.].[Node] with (nolock)
		where ViewSecurityGroup between -30 and -1
	--[6776391 in 00:00:05]
	delete n
		from #Node n 
			inner join [RDF.].[Triple] t with (nolock)
				on n.NodeID = t.Reitification
	--[3186019 in 00:00:14]

	-- Get a list of valid classes
	create table #Class (
		ClassNode bigint primary key,
		TreeDepth int,
		ClassSort int,
		Searchable bit,
		ClassName varchar(400)
	)
	insert into #Class
		select c._ClassNode, c._TreeDepth,
				row_number() over (order by IsNull(c._TreeDepth,0) desc, c._ClassName),
				(case when c._ClassNode in (select _ClassNode from [Ontology.].ClassGroupClass) then 1 else 0 end),
				c._ClassName
			from [Ontology.].ClassTreeDepth c with (nolock)
				inner join #Node n
					on c._ClassNode = n.NodeID
			where c._ClassNode <> [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#Connection')
				and c._ClassNode <> [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#ConnectionDetails')
				and c._ClassNode <> [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#Network')

	-- Get a list of searchable properties
	create table #ClassPropertySearch (
		ClassNode bigint not null,
		PropertyNode bigint not null,
		SearchWeight float
	)
	alter table #ClassPropertySearch add primary key (ClassNode, PropertyNode)
	insert into #ClassPropertySearch
		select p._ClassNode ClassNode, p._PropertyNode PropertyNode, p.SearchWeight
			from [Ontology.].[ClassProperty] p with (nolock)
				inner join #Class c
					on p._ClassNode = c.ClassNode
				inner join #Node n
					on p._PropertyNode = n.NodeID
			where p._NetworkPropertyNode IS NULL
				and p.SearchWeight > 0

	-- Get a list of view properties
	create table #ClassPropertyView (
		ClassNode bigint not null,
		PropertyNode bigint not null,
		Limit int,
		IncludeDescription tinyint,
		TagName nvarchar(1000)
	)
	alter table #ClassPropertyView add primary key (ClassNode, PropertyNode)
	insert into #ClassPropertyView
		select p._ClassNode ClassNode, p._PropertyNode PropertyNode, p.Limit, p.IncludeDescription, p._TagName
			from [Ontology.].[ClassProperty] p with (nolock)
				inner join #Class c
					on p._ClassNode = c.ClassNode
				inner join #Node n
					on p._PropertyNode = n.NodeID
			where p._NetworkPropertyNode IS NULL
				and p.IsDetail = 0


	--------------------------------------------------
	-- NodeClass
	--------------------------------------------------

	create table #NodeClass (
		NodeID bigint not null,
		ClassNode bigint not null,
		ClassSort int,
		Searchable bit
	)
	alter table #NodeClass add primary key (NodeID, ClassNode)
	declare @typeID bigint
	select @typeID = [RDF.].fnURI2NodeID('http://www.w3.org/1999/02/22-rdf-syntax-ns#type')
	insert into #NodeClass
		select distinct n.NodeID, c.ClassNode, c.ClassSort, c.Searchable
			from [RDF.].[Triple] t with (nolock)
				inner join #Node n
					on t.Subject = n.NodeID
				inner join #Class c
					on t.Object = c.ClassNode
			where t.Predicate = @typeID
	--[2388097 in 00:00:06]
	create nonclustered index #c on #NodeClass (ClassNode) include (NodeID)
	--[00:00:02]
	create nonclustered index #s on #NodeClass (Searchable, ClassSort)
	--[00:00:05]


	--------------------------------------------------
	-- NodeMap
	--------------------------------------------------

	create table #NodeSearchProperty (
		NodeID bigint not null,
		PropertyNode bigint not null,
		SearchWeight float
	)
	alter table #NodeSearchProperty add primary key (NodeID, PropertyNode)
	insert into #NodeSearchProperty
		select n.NodeID, p.PropertyNode, max(p.SearchWeight) SearchWeight
			from #NodeClass n
				inner join #ClassPropertySearch p
					on n.ClassNode = p.ClassNode
			group by n.NodeID, p.PropertyNode
	--[7281981 in 00:00:17]

	create table #NodeMap (
		NodeID bigint not null,
		MatchedByNodeID bigint not null,
		Distance int,
		Paths int,
		Weight float
	)
	alter table #NodeMap add primary key (NodeID, MatchedByNodeID)

	insert into #NodeMap (NodeID, MatchedByNodeID, Distance, Paths, Weight)
		select x.NodeID, t.Object, 1, count(*), 1-exp(sum(log(case when x.SearchWeight*t.Weight > 0.999999 then 0.000001 else 1-x.SearchWeight*t.Weight end)))
			from [RDF.].[Triple] t with (nolock)
				inner join #NodeSearchProperty x
					on t.subject = x.NodeID
						and t.predicate = x.PropertyNode
				inner join #Node n
					on t.object = n.NodeID
			where x.SearchWeight*t.Weight > 0
				and t.ViewSecurityGroup between -30 and -1
			group by x.NodeID, t.object
	--[5540963 in 00:00:43]

	declare @i int
	select @i = 1
	while @i < 10
	begin
		insert into #NodeMap (NodeID, MatchedByNodeID, Distance, Paths, Weight)
			select s.NodeID, t.MatchedByNodeID, @i+1, count(*), 1-exp(sum(log(case when s.Weight*t.Weight > 0.999999 then 0.000001 else 1-s.Weight*t.Weight end)))
				from #NodeMap s, #NodeMap t
				where s.MatchedByNodeID = t.NodeID
					and s.Distance = @i
					and t.Distance = 1
					and t.NodeID <> s.NodeID
					and not exists (
						select *
						from #NodeMap u
						where u.NodeID = s.NodeID and u.MatchedByNodeID = t.MatchedByNodeID
					)
				group by s.NodeID, t.MatchedByNodeID
		if @@ROWCOUNT = 0
			select @i = 10
		select @i = @i + 1
	end
	--[11421133, 1542809, 0 in 00:02:28]


	--------------------------------------------------
	-- NodeSummary
	--------------------------------------------------

	create table #NodeSummaryTemp (
		NodeID bigint primary key,
		ShortLabel varchar(500)
	)
	declare @labelID bigint
	select @labelID = [RDF.].fnURI2NodeID('http://www.w3.org/2000/01/rdf-schema#label')
	insert into #NodeSummaryTemp
		select t.subject NodeID, min(case when len(n.Value)>500 then left(n.Value,497)+'...' else n.Value end) Label
			from [RDF.].Triple t with (nolock)
				inner join [RDF.].Node n with (nolock)
					on t.object = n.NodeID
						and t.predicate = @labelID
						and t.subject in (select NodeID from #NodeMap)
						and t.ViewSecurityGroup between -30 and -1
						and n.ViewSecurityGroup between -30 and -1
			group by t.subject
	--[1155480 in 00:00:19]

	create table #NodeSummary (
		NodeID bigint primary key,
		ShortLabel varchar(500),
		ClassName varchar(255),
		SortOrder bigint
	)
	insert into #NodeSummary
		select s.NodeID, s.ShortLabel, c.ClassName, row_number() over (order by s.ShortLabel, s.NodeID) SortOrder
		from (
				select NodeID, ClassNode, ShortLabel
				from (
					select c.NodeID, c.ClassNode, s.ShortLabel, row_number() over (partition by c.NodeID order by c.ClassSort) k
					from #NodeClass c
						inner join #NodeSummaryTemp s
							on c.NodeID = s.NodeID
					where c.Searchable = 1
				) s
				where k = 1
			) s
			inner join #Class c
				on s.ClassNode = c.ClassNode
	--[468900 in 00:00:04]


	--------------------------------------------------
	-- NodeRDF
	--------------------------------------------------

	create table #NodePropertyExpand (
		NodeID bigint not null,
		PropertyNode bigint not null,
		Limit int,
		IncludeDescription tinyint,
		TagName nvarchar(1000)
	)
	alter table #NodePropertyExpand add primary key (NodeID, PropertyNode)
	insert into #NodePropertyExpand
		select n.NodeID, p.PropertyNode, max(p.Limit) Limit, max(p.IncludeDescription) IncludeDescription, max(p.TagName) TagName
			from #NodeClass n
				inner join #ClassPropertyView p
					on n.ClassNode = p.ClassNode
			group by n.NodeID, p.PropertyNode
	--[7698214 in 00:00:21]

	create table #NodeTag (
		NodeID bigint not null,
		TagSort int not null,
		ExpandNodeID bigint not null,
		IncludeDescription tinyint,
		TagStart nvarchar(max),
		TagValue nvarchar(max),
		TagEnd nvarchar(max)
	)
	alter table #NodeTag add primary key (NodeID, TagSort)
	insert into #NodeTag
		select e.NodeID,
				row_number() over (partition by e.NodeID order by e.TagName, o.Value, o.NodeID),
				o.NodeID, e.IncludeDescription,
 				'_TAGLT_'+e.TagName
					+(case when o.ObjectType = 0 
							then ' rdf:resource="' 
							else IsNull(' xml:lang="'+o.Language+'"','')
								+IsNull(' rdf:datatype="'+o.DataType+'"','')
								+'_TAGGT_'
							end),
				o.Value,
				(case when o.ObjectType = 0 then '"/_TAGGT_' else '_TAGLT_/'+e.TagName+'_TAGGT_' end)
			from #NodePropertyExpand e
				inner join [RDF.].[Triple] t with (nolock)
					on e.NodeID = t.subject
						and e.PropertyNode = t.predicate
						and t.ViewSecurityGroup between -30 and -1
						and ((e.Limit is null) or (t.SortOrder <= e.Limit))
				inner join [RDF.].[Node] o with (nolock)
					on t.object = o.NodeID
						and o.ViewSecurityGroup between -30 and -1
	--[7991231 in 00:04:35]

	update #NodeTag
		set TagValue = (case when charindex(char(0),cast(TagValue as varchar(max))) > 0
						then replace(replace(replace(replace(cast(TagValue as varchar(max)),char(0),''),'&','&amp;'),'<','&lt;'),'>','&gt;')
						else replace(replace(replace(TagValue,'&','&amp;'),'<','&lt;'),'>','&gt;')
						end)
		where cast(TagValue as varchar(max)) like '%[&<>'+char(0)+']%'
	--[32573 in 00:00:31]

	create unique nonclustered index idx_sn on #NodeTag (TagSort, NodeID)
	--[00:00:07]

	create table #NodeRDF (
		NodeID bigint primary key,
		RDF nvarchar(max)
	)
	insert into #NodeRDF
		select t.NodeID, 
				'_TAGLT_rdf:Description rdf:about="' + replace(replace(replace(n.Value,'&','&amp;'),'<','&lt;'),'>','&gt;') + '"_TAGGT_'
				+ t.TagStart+t.TagValue+t.TagEnd
			from #NodeTag t
				inner join [RDF.].Node n with (nolock)
					on t.NodeID = n.NodeID
			where t.TagSort = 1
	--[1157272 in 00:00:24]

	declare @k int
	select @k = 2
	while (@k > 0) and (@k < 25)
	begin
		update r
			set r.RDF = r.RDF + t.TagStart+t.TagValue+t.TagEnd
			from #NodeRDF r
				inner join #NodeTag t
					on r.NodeID = t.NodeID and t.TagSort = @k
		if @@ROWCOUNT = 0
			select @k = -1
		else
			select @k = @k + 1			
	end
	--[1157247, 1102278, 1056348, 503981, 499321, 497457, 457981, 425030, 416171, 367566, 350579, 0]
	--[00:01:35]

	update #NodeRDF
		set RDF = RDF + '_TAGLT_/rdf:Description_TAGGT_'
	--[1157272 in 00:00:08]


	--------------------------------------------------
	-- NodeExpand
	--------------------------------------------------

	create table #NodeExpand (
		NodeID bigint not null,
		ExpandNodeID bigint not null
	)
	alter table #NodeExpand add primary key (NodeID, ExpandNodeID)
	insert into #NodeExpand
		select distinct NodeID, ExpandNodeID
		from #NodeTag
		where IncludeDescription = 1
	--[3601932 in 00:00:05]


	--------------------------------------------------
	-- NodePrefix
	--------------------------------------------------

	create table #NodePrefix (
		Prefix varchar(800) not null,
		NodeID bigint not null
	)
	alter table #NodePrefix add primary key (Prefix, NodeID)
	insert into #NodePrefix (Prefix,NodeID)
		select left(n.Value,800), n.NodeID
			from [RDF.].Node n with (nolock)
				inner join #Node m
					on n.NodeID = m.NodeID
	--[3590372 in 00:00:16]


	--------------------------------------------------
	-- Update actual tables
	--------------------------------------------------

	BEGIN TRY
		BEGIN TRAN
		
			truncate table [Search.Cache].[Private.NodeMap]
			insert into [Search.Cache].[Private.NodeMap] (NodeID, MatchedByNodeID, Distance, Paths, Weight)
				select NodeID, MatchedByNodeID, Distance, Paths, Weight
					from #NodeMap
			--[18504905 in 00:02:02]

			truncate table [Search.Cache].[Private.NodeSummary]
			insert into [Search.Cache].[Private.NodeSummary] (NodeID, ShortLabel, ClassName, SortOrder)
				select NodeID, ShortLabel, ClassName, SortOrder
					from #NodeSummary
			--[468900 in 00:00:03]

			truncate table [Search.Cache].[Private.NodeClass]
			insert into [Search.Cache].[Private.NodeClass] (NodeID, Class)
				select NodeID, ClassNode
					from #NodeClass
			--[2388097 in 00:00:05]

			truncate table [Search.Cache].[Private.NodeExpand]
			insert into [Search.Cache].[Private.NodeExpand] (NodeID, ExpandNodeID)
				select NodeID, ExpandNodeID
					from #NodeExpand
			--[3601932 in 00:00:08]

			truncate table [Search.Cache].[Private.NodeRDF]
			insert into [Search.Cache].[Private.NodeRDF] (NodeID, RDF)
				select NodeID, RDF
					from #NodeRDF
			--[1157272 in 00:00:36]

			truncate table [Search.Cache].[Private.NodePrefix]
			insert into [Search.Cache].[Private.NodePrefix] (Prefix, NodeID)
				select Prefix, NodeID
					from #NodePrefix
			--[3590372 in 00:00:34]

		COMMIT
	END TRY
	BEGIN CATCH
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
		--Raise an error with the details of the exception
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		SELECT @ErrMsg = ERROR_MESSAGE(), @ErrSeverity = ERROR_SEVERITY()
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
	END CATCH
 

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Search.Cache].[Public.UpdateCache]'
GO
ALTER PROCEDURE [Search.Cache].[Public.UpdateCache]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	--------------------------------------------------
	-- Prepare lookup tables
	--------------------------------------------------

	-- Get a list of valid nodes
	create table #Node (
		NodeID bigint primary key
	)
	insert into #Node 
		select NodeID 
		from [RDF.].[Node] with (nolock)
		where ViewSecurityGroup = -1
	--[6776391 in 00:00:05]
	delete n
		from #Node n 
			inner join [RDF.].[Triple] t with (nolock)
				on n.NodeID = t.Reitification
	--[3186019 in 00:00:14]

	-- Get a list of valid classes
	create table #Class (
		ClassNode bigint primary key,
		TreeDepth int,
		ClassSort int,
		Searchable bit,
		ClassName varchar(400)
	)
	insert into #Class
		select c._ClassNode, c._TreeDepth,
				row_number() over (order by IsNull(c._TreeDepth,0) desc, c._ClassName),
				(case when c._ClassNode in (select _ClassNode from [Ontology.].ClassGroupClass) then 1 else 0 end),
				c._ClassName
			from [Ontology.].ClassTreeDepth c with (nolock)
				inner join #Node n
					on c._ClassNode = n.NodeID
			where c._ClassNode <> [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#Connection')
				and c._ClassNode <> [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#ConnectionDetails')
				and c._ClassNode <> [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#Network')

	-- Get a list of searchable properties
	create table #ClassPropertySearch (
		ClassNode bigint not null,
		PropertyNode bigint not null,
		SearchWeight float
	)
	alter table #ClassPropertySearch add primary key (ClassNode, PropertyNode)
	insert into #ClassPropertySearch
		select p._ClassNode ClassNode, p._PropertyNode PropertyNode, p.SearchWeight
			from [Ontology.].[ClassProperty] p with (nolock)
				inner join #Class c
					on p._ClassNode = c.ClassNode
				inner join #Node n
					on p._PropertyNode = n.NodeID
			where p._NetworkPropertyNode IS NULL
				and p.SearchWeight > 0

	-- Get a list of view properties
	create table #ClassPropertyView (
		ClassNode bigint not null,
		PropertyNode bigint not null,
		Limit int,
		IncludeDescription tinyint,
		TagName nvarchar(1000)
	)
	alter table #ClassPropertyView add primary key (ClassNode, PropertyNode)
	insert into #ClassPropertyView
		select p._ClassNode ClassNode, p._PropertyNode PropertyNode, p.Limit, p.IncludeDescription, p._TagName
			from [Ontology.].[ClassProperty] p with (nolock)
				inner join #Class c
					on p._ClassNode = c.ClassNode
				inner join #Node n
					on p._PropertyNode = n.NodeID
			where p._NetworkPropertyNode IS NULL
				and p.IsDetail = 0


	--------------------------------------------------
	-- NodeClass
	--------------------------------------------------

	create table #NodeClass (
		NodeID bigint not null,
		ClassNode bigint not null,
		ClassSort int,
		Searchable bit
	)
	alter table #NodeClass add primary key (NodeID, ClassNode)
	declare @typeID bigint
	select @typeID = [RDF.].fnURI2NodeID('http://www.w3.org/1999/02/22-rdf-syntax-ns#type')
	insert into #NodeClass
		select distinct n.NodeID, c.ClassNode, c.ClassSort, c.Searchable
			from [RDF.].[Triple] t with (nolock)
				inner join #Node n
					on t.Subject = n.NodeID
				inner join #Class c
					on t.Object = c.ClassNode
			where t.Predicate = @typeID
	--[2388097 in 00:00:06]
	create nonclustered index #c on #NodeClass (ClassNode) include (NodeID)
	--[00:00:02]
	create nonclustered index #s on #NodeClass (Searchable, ClassSort)
	--[00:00:05]


	--------------------------------------------------
	-- NodeMap
	--------------------------------------------------

	create table #NodeSearchProperty (
		NodeID bigint not null,
		PropertyNode bigint not null,
		SearchWeight float
	)
	alter table #NodeSearchProperty add primary key (NodeID, PropertyNode)
	insert into #NodeSearchProperty
		select n.NodeID, p.PropertyNode, max(p.SearchWeight) SearchWeight
			from #NodeClass n
				inner join #ClassPropertySearch p
					on n.ClassNode = p.ClassNode
			group by n.NodeID, p.PropertyNode
	--[7281981 in 00:00:17]

	create table #NodeMap (
		NodeID bigint not null,
		MatchedByNodeID bigint not null,
		Distance int,
		Paths int,
		Weight float
	)
	alter table #NodeMap add primary key (NodeID, MatchedByNodeID)

	insert into #NodeMap (NodeID, MatchedByNodeID, Distance, Paths, Weight)
		select x.NodeID, t.Object, 1, count(*), 1-exp(sum(log(case when x.SearchWeight*t.Weight > 0.999999 then 0.000001 else 1-x.SearchWeight*t.Weight end)))
			from [RDF.].[Triple] t with (nolock)
				inner join #NodeSearchProperty x
					on t.subject = x.NodeID
						and t.predicate = x.PropertyNode
				inner join #Node n
					on t.object = n.NodeID
			where x.SearchWeight*t.Weight > 0
				and t.ViewSecurityGroup = -1
			group by x.NodeID, t.object
	--[5540963 in 00:00:43]

	declare @i int
	select @i = 1
	while @i < 10
	begin
		insert into #NodeMap (NodeID, MatchedByNodeID, Distance, Paths, Weight)
			select s.NodeID, t.MatchedByNodeID, @i+1, count(*), 1-exp(sum(log(case when s.Weight*t.Weight > 0.999999 then 0.000001 else 1-s.Weight*t.Weight end)))
				from #NodeMap s, #NodeMap t
				where s.MatchedByNodeID = t.NodeID
					and s.Distance = @i
					and t.Distance = 1
					and t.NodeID <> s.NodeID
					and not exists (
						select *
						from #NodeMap u
						where u.NodeID = s.NodeID and u.MatchedByNodeID = t.MatchedByNodeID
					)
				group by s.NodeID, t.MatchedByNodeID
		if @@ROWCOUNT = 0
			select @i = 10
		select @i = @i + 1
	end
	--[11421133, 1542809, 0 in 00:02:28]


	--------------------------------------------------
	-- NodeSummary
	--------------------------------------------------

	create table #NodeSummaryTemp (
		NodeID bigint primary key,
		ShortLabel varchar(500)
	)
	declare @labelID bigint
	select @labelID = [RDF.].fnURI2NodeID('http://www.w3.org/2000/01/rdf-schema#label')
	insert into #NodeSummaryTemp
		select t.subject NodeID, min(case when len(n.Value)>500 then left(n.Value,497)+'...' else n.Value end) Label
			from [RDF.].Triple t with (nolock)
				inner join [RDF.].Node n with (nolock)
					on t.object = n.NodeID
						and t.predicate = @labelID
						and t.subject in (select NodeID from #NodeMap)
						and t.ViewSecurityGroup = -1
						and n.ViewSecurityGroup = -1
			group by t.subject
	--[1155480 in 00:00:19]

	create table #NodeSummary (
		NodeID bigint primary key,
		ShortLabel varchar(500),
		ClassName varchar(255),
		SortOrder bigint
	)
	insert into #NodeSummary
		select s.NodeID, s.ShortLabel, c.ClassName, row_number() over (order by s.ShortLabel, s.NodeID) SortOrder
		from (
				select NodeID, ClassNode, ShortLabel
				from (
					select c.NodeID, c.ClassNode, s.ShortLabel, row_number() over (partition by c.NodeID order by c.ClassSort) k
					from #NodeClass c
						inner join #NodeSummaryTemp s
							on c.NodeID = s.NodeID
					where c.Searchable = 1
				) s
				where k = 1
			) s
			inner join #Class c
				on s.ClassNode = c.ClassNode
	--[468900 in 00:00:04]


	--------------------------------------------------
	-- NodeRDF
	--------------------------------------------------

	create table #NodePropertyExpand (
		NodeID bigint not null,
		PropertyNode bigint not null,
		Limit int,
		IncludeDescription tinyint,
		TagName nvarchar(1000)
	)
	alter table #NodePropertyExpand add primary key (NodeID, PropertyNode)
	insert into #NodePropertyExpand
		select n.NodeID, p.PropertyNode, max(p.Limit) Limit, max(p.IncludeDescription) IncludeDescription, max(p.TagName) TagName
			from #NodeClass n
				inner join #ClassPropertyView p
					on n.ClassNode = p.ClassNode
			group by n.NodeID, p.PropertyNode
	--[7698214 in 00:00:21]

	create table #NodeTag (
		NodeID bigint not null,
		TagSort int not null,
		ExpandNodeID bigint not null,
		IncludeDescription tinyint,
		TagStart nvarchar(max),
		TagValue nvarchar(max),
		TagEnd nvarchar(max)
	)
	alter table #NodeTag add primary key (NodeID, TagSort)
	insert into #NodeTag
		select e.NodeID,
				row_number() over (partition by e.NodeID order by e.TagName, o.Value, o.NodeID),
				o.NodeID, e.IncludeDescription,
 				'_TAGLT_'+e.TagName
					+(case when o.ObjectType = 0 
							then ' rdf:resource="' 
							else IsNull(' xml:lang="'+o.Language+'"','')
								+IsNull(' rdf:datatype="'+o.DataType+'"','')
								+'_TAGGT_'
							end),
				o.Value,
				(case when o.ObjectType = 0 then '"/_TAGGT_' else '_TAGLT_/'+e.TagName+'_TAGGT_' end)
			from #NodePropertyExpand e
				inner join [RDF.].[Triple] t with (nolock)
					on e.NodeID = t.subject
						and e.PropertyNode = t.predicate
						and t.ViewSecurityGroup = -1
						and ((e.Limit is null) or (t.SortOrder <= e.Limit))
				inner join [RDF.].[Node] o with (nolock)
					on t.object = o.NodeID
						and o.ViewSecurityGroup = -1
	--[7991231 in 00:04:35]

	update #NodeTag
		set TagValue = (case when charindex(char(0),cast(TagValue as varchar(max))) > 0
						then replace(replace(replace(replace(cast(TagValue as varchar(max)),char(0),''),'&','&amp;'),'<','&lt;'),'>','&gt;')
						else replace(replace(replace(TagValue,'&','&amp;'),'<','&lt;'),'>','&gt;')
						end)
		where cast(TagValue as varchar(max)) like '%[&<>'+char(0)+']%'
	--[32573 in 00:00:31]

	create unique nonclustered index idx_sn on #NodeTag (TagSort, NodeID)
	--[00:00:07]

	create table #NodeRDF (
		NodeID bigint primary key,
		RDF nvarchar(max)
	)
	insert into #NodeRDF
		select t.NodeID, 
				'_TAGLT_rdf:Description rdf:about="' + replace(replace(replace(n.Value,'&','&amp;'),'<','&lt;'),'>','&gt;') + '"_TAGGT_'
				+ t.TagStart+t.TagValue+t.TagEnd
			from #NodeTag t
				inner join [RDF.].Node n with (nolock)
					on t.NodeID = n.NodeID
			where t.TagSort = 1
	--[1157272 in 00:00:24]

	declare @k int
	select @k = 2
	while (@k > 0) and (@k < 25)
	begin
		update r
			set r.RDF = r.RDF + t.TagStart+t.TagValue+t.TagEnd
			from #NodeRDF r
				inner join #NodeTag t
					on r.NodeID = t.NodeID and t.TagSort = @k
		if @@ROWCOUNT = 0
			select @k = -1
		else
			select @k = @k + 1			
	end
	--[1157247, 1102278, 1056348, 503981, 499321, 497457, 457981, 425030, 416171, 367566, 350579, 0]
	--[00:01:35]

	update #NodeRDF
		set RDF = RDF + '_TAGLT_/rdf:Description_TAGGT_'
	--[1157272 in 00:00:08]


	--------------------------------------------------
	-- NodeExpand
	--------------------------------------------------

	create table #NodeExpand (
		NodeID bigint not null,
		ExpandNodeID bigint not null
	)
	alter table #NodeExpand add primary key (NodeID, ExpandNodeID)
	insert into #NodeExpand
		select distinct NodeID, ExpandNodeID
		from #NodeTag
		where IncludeDescription = 1
	--[3601932 in 00:00:05]


	--------------------------------------------------
	-- NodePrefix
	--------------------------------------------------

	create table #NodePrefix (
		Prefix varchar(800) not null,
		NodeID bigint not null
	)
	alter table #NodePrefix add primary key (Prefix, NodeID)
	insert into #NodePrefix (Prefix,NodeID)
		select left(n.Value,800), n.NodeID
			from [RDF.].Node n with (nolock)
				inner join #Node m
					on n.NodeID = m.NodeID
	--[3590372 in 00:00:16]


	--------------------------------------------------
	-- Update actual tables
	--------------------------------------------------

	BEGIN TRY
		BEGIN TRAN
		
			truncate table [Search.Cache].[Public.NodeMap]
			insert into [Search.Cache].[Public.NodeMap] (NodeID, MatchedByNodeID, Distance, Paths, Weight)
				select NodeID, MatchedByNodeID, Distance, Paths, Weight
					from #NodeMap
			--[18504905 in 00:02:02]

			truncate table [Search.Cache].[Public.NodeSummary]
			insert into [Search.Cache].[Public.NodeSummary] (NodeID, ShortLabel, ClassName, SortOrder)
				select NodeID, ShortLabel, ClassName, SortOrder
					from #NodeSummary
			--[468900 in 00:00:03]

			truncate table [Search.Cache].[Public.NodeClass]
			insert into [Search.Cache].[Public.NodeClass] (NodeID, Class)
				select NodeID, ClassNode
					from #NodeClass
			--[2388097 in 00:00:05]

			truncate table [Search.Cache].[Public.NodeExpand]
			insert into [Search.Cache].[Public.NodeExpand] (NodeID, ExpandNodeID)
				select NodeID, ExpandNodeID
					from #NodeExpand
			--[3601932 in 00:00:08]

			truncate table [Search.Cache].[Public.NodeRDF]
			insert into [Search.Cache].[Public.NodeRDF] (NodeID, RDF)
				select NodeID, RDF
					from #NodeRDF
			--[1157272 in 00:00:36]

			truncate table [Search.Cache].[Public.NodePrefix]
			insert into [Search.Cache].[Public.NodePrefix] (Prefix, NodeID)
				select Prefix, NodeID
					from #NodePrefix
			--[3590372 in 00:00:34]

		COMMIT
	END TRY
	BEGIN CATCH
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
		--Raise an error with the details of the exception
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		SELECT @ErrMsg = ERROR_MESSAGE(), @ErrSeverity = ERROR_SEVERITY()
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
	END CATCH
 

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Ontology.].[ClassGroup]'
GO
ALTER TABLE [Ontology.].[ClassGroup] ADD
[IsVisible] [bit] NULL
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.Pubmed.AddPMIDs]'
GO
ALTER PROCEDURE [Profile.Data].[Publication.Pubmed.AddPMIDs] (@personid INT,
																		@PMIDxml XML)
AS
BEGIN
	SET NOCOUNT ON;	
	

	BEGIN TRY
		BEGIN TRAN		 
			  delete from [Profile.Data].[Publication.PubMed.Disambiguation] where personid = @personid				 
			  -- Add publications_include records
			  INSERT INTO [Profile.Data].[Publication.PubMed.Disambiguation] (personid,pmid)
			  SELECT @personid,
					 D.element.value('.','INT') pmid		 
				FROM @PMIDxml.nodes('//PMID') AS D(element)
			   WHERE NOT EXISTS(SELECT TOP 1 * FROM [Profile.Data].[Publication.PubMed.Disambiguation]	 dp WHERE personid = @personid and dp.pmid = D.element.value('.','INT'))	

		
		COMMIT
	END TRY
	BEGIN CATCH
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK

		-- Raise an error with the details of the exception
		SELECT @ErrMsg = 'usp_CheckPMIDList FAILED WITH : ' + ERROR_MESSAGE(),
					 @ErrSeverity = ERROR_SEVERITY()

		RAISERROR(@ErrMsg, @ErrSeverity, 1)
			 
	END CATCH				
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.Pubmed.AddDisambiguationLog]'
GO
ALTER  PROCEDURE  [Profile.Data].[Publication.Pubmed.AddDisambiguationLog] (@batchID UNIQUEIDENTIFIER, 
												@personID INT,
												@actionValue INT,
												@action VARCHAR(200),
												@actionText varchar(max) = null )
AS
BEGIN
	IF @action='StartService'
		BEGIN
			INSERT INTO [Profile.Data].[Publication.PubMed.DisambiguationAudit]  (BatchID,BatchCount,PersonID,ServiceCallStart)
			VALUES (@batchID,@actionValue,@personID,GETDATE())
		END
	IF @action='EndService'
		BEGIN
			UPDATE [Profile.Data].[Publication.PubMed.DisambiguationAudit] 
			   SET ServiceCallEnd = GETDATE(),
				   ServiceCallPubsFound  =@actionValue
			 WHERE batchID=@batchID
			   AND personid=@personID
		END
	IF @action='LocalCounts'
		BEGIN
			UPDATE [Profile.Data].[Publication.PubMed.DisambiguationAudit] 
			   SET ServiceCallNewPubs = @actionValue,
				   ServiceCallExistingPubs  =ServiceCallPubsFound-@actionValue
			 WHERE batchID=@batchID
			   AND personid=@personID
		END
	IF @action='AuthorComplete'
		BEGIN
			UPDATE [Profile.Data].[Publication.PubMed.DisambiguationAudit] 
			   SET ServiceCallPubsAdded = @actionValue,
				   ProcessEnd  =GETDATE(),
				   Success= 1
			 WHERE batchID=@batchID
			   AND personid=@personID
		END
	IF @action='Error'
		BEGIN
			UPDATE [Profile.Data].[Publication.PubMed.DisambiguationAudit] 
			   SET ErrorText = @actionText,
				   ProcessEnd  =GETDATE(),
				   Success=0
			 WHERE batchID=@batchID
			   AND personid=@personID
		END
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Person.DeletePhoto]'
GO
ALTER PROCEDURE [Profile.Data].[Person.DeletePhoto](@PhotoID INT)
AS
BEGIN

	-- Delete the triple
	DECLARE @NodeID BIGINT
	SELECT @NodeID = PersonNodeID
		FROM [Profile.Data].[vwPerson.Photo]
		WHERE PhotoID = @PhotoID
	IF (@NodeID IS NOT NULL)
		EXEC [RDF.].[DeleteTriple] @SubjectID = @NodeID, @PredicateURI = 'http://profiles.catalyst.harvard.edu/ontology/prns#mainImage'

	-- Delete the photo
	DELETE 
		FROM [Profile.Data].[Person.Photo]
		WHERE PhotoID=@PhotoID 

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Module].[NetworkAuthorshipTimeline.Person.GetData]'
GO
ALTER PROCEDURE [Profile.Module].[NetworkAuthorshipTimeline.Person.GetData]
	@NodeID BIGINT,
	@ShowAuthorPosition BIT = 0
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @PersonID INT
 	SELECT @PersonID = CAST(m.InternalID AS INT)
		FROM [RDF.Stage].[InternalNodeMap] m, [RDF.].Node n
		WHERE m.Status = 3 AND m.ValueHash = n.ValueHash AND n.NodeID = @NodeID
 
    -- Insert statements for procedure here
	declare @gc varchar(max)

	declare @y table (
		y int,
		A int,
		B int,
		C int,
		T int
	)

	insert into @y (y,A,B,C,T)
		select n.n y, coalesce(t.A,0) A, coalesce(t.B,0) B, coalesce(t.C,0) C, coalesce(t.T,0) T
		from [Utility.Math].[N] left outer join (
			select (case when y < 1970 then 1970 else y end) y,
				sum(case when r in ('F','S') then 1 else 0 end) A,
				sum(case when r not in ('F','S','L') then 1 else 0 end) B,
				sum(case when r in ('L') then 1 else 0 end) C,
				count(*) T
			from (
				select coalesce(p.AuthorPosition,'U') r, year(coalesce(p.pubdate,m.publicationdt,'1/1/1970')) y
				from [Profile.Data].[Publication.Person.Include] a
					left outer join [Profile.Cache].[Publication.PubMed.AuthorPosition] p on a.pmid = p.pmid and p.personid = a.personid
					left outer join [Profile.Data].[Publication.MyPub.General] m on a.mpid = m.mpid
				where a.personid = @PersonID
			) t
			group by y
		) t on n.n = t.y
		where n.n between 1980 and year(getdate())

	declare @x int

	--select @x = max(A+B+C)
	--	from @y

	select @x = max(T)
		from @y

	if coalesce(@x,0) > 0
	begin
		declare @v varchar(1000)
		declare @z int
		declare @k int
		declare @i int

		set @z = power(10,floor(log(@x)/log(10)))
		set @k = floor(@x/@z)
		if @x > @z*@k
			select @k = @k + 1
		if @k > 5
			select @k = floor(@k/2.0+0.5), @z = @z*2

		set @v = ''
		set @i = 0
		while @i <= @k
		begin
			set @v = @v + '|' + cast(@z*@i as varchar(50))
			set @i = @i + 1
		end
		set @v = '|0|'+cast(@x as varchar(50))
		--set @v = '|0|50|100'

		declare @h varchar(1000)
		set @h = ''
		select @h = @h + '|' + (case when y % 2 = 1 then '' else ''''+right(cast(y as varchar(50)),2) end)
			from @y
			order by y 

		declare @w float
		--set @w = @k*@z
		set @w = @x

		declare @c varchar(50)
		declare @d varchar(max)
		set @d = ''

		if @ShowAuthorPosition = 0
		begin
			select @d = @d + cast(floor(0.5 + 100*T/@w) as varchar(50)) + ','
				from @y
				order by y
			set @d = left(@d,len(@d)-1)

			--set @c = 'AC1B30'
			set @c = '80B1D3'
			set @gc = '//chart.googleapis.com/chart?chs=595x100&chf=bg,s,ffffff|c,s,ffffff&chxt=x,y&chxl=0:' + @h + '|1:' + @v + '&cht=bvs&chd=t:' + @d + '&chdl=Publications&chco='+@c+'&chbh=10'
		end
		else
		begin
			select @d = @d + cast(floor(0.5 + 100*A/@w) as varchar(50)) + ','
				from @y
				order by y
			set @d = left(@d,len(@d)-1) + '|'
			select @d = @d + cast(floor(0.5 + 100*B/@w) as varchar(50)) + ','
				from @y
				order by y
			set @d = left(@d,len(@d)-1) + '|'
			select @d = @d + cast(floor(0.5 + 100*C/@w) as varchar(50)) + ','
				from @y
				order by y
			set @d = left(@d,len(@d)-1)

			set @c = 'FB8072,B3DE69,80B1D3'
			set @gc = '//chart.googleapis.com/chart?chs=595x100&chf=bg,s,ffffff|c,s,ffffff&chxt=x,y&chxl=0:' + @h + '|1:' + @v + '&cht=bvs&chd=t:' + @d + '&chdl=First+Author|Middle or Unkown|Last+Author&chco='+@c+'&chbh=10'
		end

		select @gc gc --, @w w

		--select * from @y order by y

	end

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Person.AddPhoto]'
GO
ALTER procedure [Profile.Data].[Person.AddPhoto]
	@PersonID INT,
	@Photo VARBINARY(MAX)=NULL,
	@PhotoLink NVARCHAR(MAX)=NULL
AS
BEGIN
	
	SET NOCOUNT ON;

	-- Only one custom photo per user, so replace any existing custom photos

	IF EXISTS (SELECT 1 FROM [Profile.Data].[Person.Photo] WHERE PersonID = @personid)
		BEGIN 
			UPDATE [Profile.Data].[Person.Photo] SET photo = @photo, PhotoLink = @PhotoLink WHERE PersonID = @personid 
		END
	ELSE 
		BEGIN 
			INSERT INTO [Profile.Data].[Person.Photo](PersonID ,Photo,PhotoLink) VALUES(@PersonID,@Photo,@PhotoLink)
		END 
	
	DECLARE @NodeID BIGINT
	DECLARE @URI VARCHAR(400)
	DECLARE @URINodeID BIGINT
	SELECT @NodeID = PersonNodeID, @URI = URI
		FROM [Profile.Data].[vwPerson.Photo]
		WHERE PersonID = @PersonID
	IF (@NodeID IS NOT NULL AND @URI IS NOT NULL)
		BEGIN
			EXEC [RDF.].[GetStoreNode] @Value = @URI, @NodeID = @URINodeID OUTPUT
			IF (@URINodeID IS NOT NULL)
				EXEC [RDF.].[GetStoreTriple]	@SubjectID = @NodeID,
												@PredicateURI = 'http://profiles.catalyst.harvard.edu/ontology/prns#mainImage',
												@ObjectID = @URINodeID
		END
 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Ontology.].[CleanUp]'
GO
ALTER PROCEDURE [Ontology.].[CleanUp]
	@Action varchar(100) = NULL
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	-- This stored procedure contains code to help developers manage
	-- content in several ontology tables.
	
	-------------------------------------------------------------
	-- View the contents of the tables
	-------------------------------------------------------------

	if @Action = 'ShowTables'
	begin
		select * from [Ontology.].ClassGroup
		select * from [Ontology.].ClassGroupClass
		select * from [Ontology.].ClassProperty
		select * from [Ontology.].DataMap
		select * from [Ontology.].Namespace
		select * from [Ontology.].PropertyGroup
		select * from [Ontology.].PropertyGroupProperty
		select * from [Ontology.Import].[Triple]
		select * from [Ontology.Import].OWL
		select * from [Ontology.Presentation].General
	end
	
	-------------------------------------------------------------
	-- Insert missing records, use default values
	-------------------------------------------------------------

	if @Action = 'AddMissingRecords'
	begin

		insert into [Ontology.].ClassProperty (ClassPropertyID, Class, NetworkProperty, Property, IsDetail, Limit, IncludeDescription, IncludeNetwork, SearchWeight, CustomDisplay, CustomEdit, ViewSecurityGroup, EditSecurityGroup, EditPermissionsSecurityGroup, EditExistingSecurityGroup, EditAddNewSecurityGroup, EditAddExistingSecurityGroup, EditDeleteSecurityGroup, MinCardinality, MaxCardinality, CustomEditModule)
			select ClassPropertyID, Class, NetworkProperty, Property, IsDetail, Limit, IncludeDescription, IncludeNetwork, SearchWeight, CustomDisplay, CustomEdit, ViewSecurityGroup, EditSecurityGroup, EditPermissionsSecurityGroup, EditExistingSecurityGroup, EditAddNewSecurityGroup, EditAddExistingSecurityGroup, EditDeleteSecurityGroup, MinCardinality, MaxCardinality, CustomEditModule
				from [Ontology.].vwMissingClassProperty

		insert into [Ontology.].PropertyGroupProperty (PropertyGroupURI, PropertyURI, SortOrder)
			select PropertyGroupURI, PropertyURI, SortOrder
				from [Ontology.].vwMissingPropertyGroupProperty

	end

	-------------------------------------------------------------
	-- Update IDs using the default sort order
	-------------------------------------------------------------

	if @Action = 'UpdateIDs'
	begin
		
		update x
			set x.ClassPropertyID = y.k
			from [Ontology.].ClassProperty x, (
				select *, row_number() over (order by (case when NetworkProperty is null then 0 else 1 end), Class, NetworkProperty, IsDetail, IncludeNetwork, Property) k
					from [Ontology.].ClassProperty
			) y
			where x.Class = y.Class and x.Property = y.Property
				and ((x.NetworkProperty is null and y.NetworkProperty is null) or (x.NetworkProperty = y.NetworkProperty))

		update x
			set x.DataMapID = y.k
			from [Ontology.].DataMap x, (
				select *, row_number() over (order by	(case when Property is null then 0 when NetworkProperty is null then 1 else 2 end), 
														(case when Class = 'http://profiles.catalyst.harvard.edu/ontology/prns#User' then 0 else 1 end), 
														Class,
														(case when NetworkProperty = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type' then 0 when NetworkProperty = 'http://www.w3.org/2000/01/rdf-schema#label' then 1 else 2 end),
														NetworkProperty, 
														(case when Property = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type' then 0 when Property = 'http://www.w3.org/2000/01/rdf-schema#label' then 1 else 2 end),
														MapTable,
														Property
														) k
					from [Ontology.].DataMap
			) y
			where x.Class = y.Class and x.sInternalType = y.sInternalType
				and ((x.Property is null and y.Property is null) or (x.Property = y.Property))
				and ((x.NetworkProperty is null and y.NetworkProperty is null) or (x.NetworkProperty = y.NetworkProperty))

		update x
			set x.PresentationID = y.k
			from [Ontology.Presentation].General x, (
				select *, row_number() over (order by	(case when Type = 'E' then 1 else 0 end), 
														Subject,
														(case Type when 'P' then 1 when 'N' then 2 else 3 end),
														Predicate, Object
														) k
					from [Ontology.Presentation].General
			) y
			where x.Type = y.Type
				and ((x.Subject is null and y.Subject is null) or (x.Subject = y.Subject))
				and ((x.Predicate is null and y.Predicate is null) or (x.Predicate = y.Predicate))
				and ((x.Object is null and y.Object is null) or (x.Object = y.Object))	

	end

	-------------------------------------------------------------
	-- Update derived and calculated fields
	-------------------------------------------------------------

	if @Action = 'UpdateFields'
	begin
		exec [Ontology.].UpdateDerivedFields
		exec [Ontology.].UpdateCounts
	end
    
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Import].[Beta.LoadData]'
GO
ALTER procedure [Profile.Import].[Beta.LoadData] (@SourceDBName varchar(max))
AS BEGIN
	 
	SET NOCOUNT ON;
 
	   /* 
 
	This stored procedure imports a subset of data from a Profiles RNS Beta
	instance into the Profiles RNS 1.0 Extended Schema tables. 
 
	Input parameters:
		@SourceDBName				source db to pull beta data from.		  
 
	Test Call:
		[Utility.Application].[uspImportBetaData] resnav_people_hmsopen
		
	*/
	DECLARE @sql NVARCHAR(MAX) 
	
	-- Toggle off fkey constraints
	ALTER TABLE [Profile.Data].[Person.FilterRelationship]  NOCHECK CONSTRAINT FK_person_type_relationships_person
	ALTER TABLE [Profile.Data].[Person.FilterRelationship]  NOCHECK CONSTRAINT FK_person_type_relationships_person_types	
	ALTER TABLE [Profile.Data].[Publication.Person.Include]  NOCHECK CONSTRAINT FK_publications_include_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.MyPub.General]  NOCHECK CONSTRAINT FK_my_pubs_general_person
	ALTER TABLE [Profile.Data].[Publication.Person.Include]  NOCHECK CONSTRAINT FK_publications_include_person
	ALTER TABLE [Profile.Data].[Publication.Person.Include]  NOCHECK CONSTRAINT FK_publications_include_my_pubs_general 
	ALTER TABLE [Profile.Data].[Publication.PubMed.Accession]  NOCHECK CONSTRAINT  FK_pm_pubs_accessions_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Author]  NOCHECK CONSTRAINT  FK_pm_pubs_authors_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Chemical]  NOCHECK CONSTRAINT  FK_pm_pubs_chemicals_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Databank]  NOCHECK CONSTRAINT  FK_pm_pubs_databanks_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Grant]  NOCHECK CONSTRAINT FK_pm_pubs_grants_pm_pubs_general
	
	-- [profile.data].[Organization.Department] 
	TRUNCATE TABLE [profile.data].[Organization.Department]
	SET IDENTITY_INSERT [profile.data].[Organization.Department] ON 
	SELECT @sql = 'SELECT DepartmentID,DepartmentName,Visible FROM '+ @SourceDBName + '.dbo.department'
	INSERT INTO [profile.data].[Organization.Department](DepartmentID,DepartmentName,Visible)
	EXEC sp_executesql @sql
	SET IDENTITY_INSERT [profile.data].[Organization.Department] OFF	
	
	--[profile.data].[Organization.Division]dbo.division
	TRUNCATE TABLE [profile.data].[Organization.division]
	SET IDENTITY_INSERT [profile.data].[Organization.Division] ON 
	SELECT @sql = 'SELECT DivisionID,DivisionName FROM '+ @SourceDBName + '.dbo.Division'
	INSERT INTO [profile.data].[Organization.Division](DivisionID,DivisionName)
	EXEC sp_executesql @sql	
	SET IDENTITY_INSERT [profile.data].[Organization.Division] OFF	
	
	--[profile.data].[Organization.Institution]dbo.institution
	TRUNCATE TABLE [profile.data].[Organization.institution]
	SET IDENTITY_INSERT [profile.data].[Organization.institution] ON 
	SELECT @sql = 'SELECT institutionID,institutionName,InstitutionAbbreviation FROM '+ @SourceDBName + '.dbo.institution'
	INSERT INTO [profile.data].[Organization.institution](institutionID,institutionName,InstitutionAbbreviation)
	EXEC sp_executesql @sql	
	SET IDENTITY_INSERT [profile.data].[Organization.institution] OFF	
	
	--	[profile.data].[concept.mesh.descriptor]dbo.mesh_descriptors institution
	TRUNCATE TABLE [profile.data].[concept.mesh.descriptor]
	SELECT @sql = 'SELECT DescriptorUI,DescriptorName FROM '+ @SourceDBName + '.dbo.mesh_descriptors'
	INSERT INTO [profile.data].[concept.mesh.descriptor](DescriptorUI,DescriptorName )
	EXEC sp_executesql @sql	 	
	
	--	[profile.data].[concept.mesh.tree]dbo.mesh_tree
	TRUNCATE TABLE [profile.data].[concept.mesh.tree]
	SELECT @sql = 'SELECT DescriptorUI,TreeNumber FROM '+ @SourceDBName + '.dbo.mesh_tree'
	INSERT INTO [profile.data].[concept.mesh.tree](DescriptorUI,TreeNumber )
	EXEC sp_executesql @sql	 
	
	--	[profile.data].[concept.mesh.SemanticGroup]dbo.mesh_semantic_groups
	TRUNCATE TABLE [profile.data].[concept.mesh.SemanticGroup]
	SELECT @sql = 'SELECT DescriptorUI,SemanticGroupUI,SemanticGroupName FROM '+ @SourceDBName + '.dbo.mesh_semantic_groups'
	INSERT INTO [profile.data].[concept.mesh.SemanticGroup](DescriptorUI,SemanticGroupUI,SemanticGroupName  )
	EXEC sp_executesql @sql	 	
	
	--  [profile.cache].[Publication.PubMed.AuthorPosition], dbo.cache_pm_author_position
	TRUNCATE TABLE [profile.cache].[Publication.PubMed.AuthorPosition]
	SELECT @sql =  'SELECT [PersonID],[PMID],[AuthorPosition],[AuthorWeight],[PubDate],[PubYear],[YearWeight] FROM '+ @SourceDBName + '.dbo.cache_pm_author_position'
	INSERT INTO [profile.cache].[Publication.PubMed.AuthorPosition]([PersonID],[PMID],[AuthorPosition],[AuthorWeight],[PubDate],[PubYear],[YearWeight]  )
	EXEC sp_executesql @sql	 
	 
	--	[Profile.Data].[Person]dbo.person
	DELETE FROM [profile.Data].[Person]
	SET IDENTITY_INSERT [profile.data].[Person] ON 
	SELECT @sql = 'SELECT p.[PersonID],p.[UserID],[FirstName],[LastName],[MiddleName],[DisplayName],[Suffix],p.[IsActive],[EmailAddr],[Phone],[Fax],[AddressLine1],[AddressLine2],[AddressLine3],[AddressLine4],[City],[State],[Zip],[Building],[Floor],[Room],[AddressString],[Latitude],[Longitude],[GeoScore],pa.[FacultyRankID],p.[PersonID],isnull([Visible], 1) FROM '+ @SourceDBName + '.dbo.person p'
	+ ' left join ' + @SourceDBName + '.dbo.person_affiliations pa on p.PersonID = pa.PersonID and PA.IsPrimary = 1'
	INSERT INTO [profile.data].[Person]([PersonID],[UserID],[FirstName],[LastName],[MiddleName],[DisplayName],[Suffix],[IsActive],[EmailAddr],[Phone],[Fax],[AddressLine1],[AddressLine2],[AddressLine3],[AddressLine4],[City],[State],[Zip],[Building],[Floor],[Room],[AddressString],[Latitude],[Longitude],[GeoScore],[FacultyRankID],[InternalUsername],[Visible]  )
	EXEC sp_executesql @sql	 
	SET IDENTITY_INSERT [profile.data].[Person] OFF 		
	
	--	[Profile.Data].[Person.FilterRelationship]dbo.person_filter_relationships
	TRUNCATE TABLE [profile.Data].[Person.FilterRelationship] 
	SELECT @sql = 'SELECT [PersonID],[PersonFilterid] FROM '+ @SourceDBName + '.dbo.person_filter_relationships'
	INSERT INTO [profile.data].[Person.FilterRelationship]([PersonID],[PersonFilterid] )
	EXEC sp_executesql @sql	   
	
	--	[Profile.Data].[Person.Filter]dbo.person_filters
	SET IDENTITY_INSERT [profile.data].[Person.Filter] ON 
	DELETE FROM [profile.Data].[Person.Filter] 
	SELECT @sql = 'SELECT [PersonFilterID],[PersonFilter],[PersonFilterCategory],[PersonFilterSort] FROM '+ @SourceDBName + '.dbo.person_filters'
	INSERT INTO [profile.data].[Person.Filter]([PersonFilterID],[PersonFilter],[PersonFilterCategory],[PersonFilterSort] )
	EXEC sp_executesql @sql	   
	SET IDENTITY_INSERT [profile.data].[Person.Filter] OFF 
		
	--	[profile.data].[Person.Affiliation]dbo.person_affiliations
	SET IDENTITY_INSERT [profile.data].[Person.Affiliation] ON 
	TRUNCATE TABLE [profile.Data].[Person.Affiliation] 
	SELECT @sql = 'SELECT [PersonAffiliationID],[PersonID],[SortOrder],[IsActive],[IsPrimary],[InstitutionID],[DepartmentID],[DivisionID],[Title],[EmailAddress],[FacultyRankID] 
					FROM '+ @SourceDBName + '.dbo.person_affiliations a
						LEFT OUTER JOIN '+ @SourceDBName + '.dbo.institution_fullname i ON a.[InstitutionFullnameID] = i.[InstitutionFullnameID] 
						LEFT OUTER JOIN '+ @SourceDBName + '.dbo.department_fullname d ON a.[DepartmentFullNameID] = d.[DepartmentFullNameID]
						LEFT OUTER JOIN '+ @SourceDBName + '.dbo.division_fullname v ON a.[DivisionFullnameID] = v.[DivisionFullnameID]'
	INSERT INTO [profile.data].[Person.Affiliation]([PersonAffiliationID],[PersonID],[SortOrder],[IsActive],[IsPrimary],[InstitutionID],[DepartmentID],[DivisionID],[Title],[EmailAddress],[FacultyRankID] )
	EXEC sp_executesql @sql	   
	SET IDENTITY_INSERT [profile.data].[Person.Affiliation] OFF 	
	
	--	[Profile.Data].[Person.Award]dbo.awards 
	TRUNCATE TABLE [profile.Import].[Beta.Award] 
	SELECT @sql = 'SELECT [AwardID],[PersonID],[Yr],[Yr2],[AwardNM],[AwardingInst] FROM '+ @SourceDBName + '.dbo.awards'
	INSERT INTO [profile.Import].[Beta.Award]([AwardID],[PersonID],[Yr],[Yr2],[AwardNM],[AwardingInst] )
	EXEC sp_executesql @sql	    
	
	--	[Profile.Data].[Person.FacultyRank]dbo.faculty_rank
	TRUNCATE TABLE [profile.Data].[Person.FacultyRank] 
	SELECT @sql = 'SELECT DISTINCT [FacultyRank],[FacultyRankSort],[Visible] FROM '+ @SourceDBName + '.dbo. faculty_rank'
	INSERT INTO [profile.data].[Person.FacultyRank]([FacultyRank],[FacultyRankSort],[Visible] )
	EXEC sp_executesql @sql	   
	
	--	[profile.data].[person.narrative]dbo.narratives  
	TRUNCATE TABLE [profile.Import].[Beta.Narrative] 
	SELECT @sql = 'SELECT [PersonID],[NarrativeMain] FROM '+ @SourceDBName + '.dbo.narratives'
	INSERT INTO [profile.Import].[Beta.Narrative]([PersonID],[NarrativeMain] )
	EXEC sp_executesql @sql	    	
	
	--	[Profile.Cache].[SNA.Coauthor]dbo.sna_coauthors 
	TRUNCATE TABLE [Profile.Cache].[SNA.Coauthor]
	SELECT @sql = 'SELECT [PersonID1],[PersonID2],[i],[j],[w],[FirstPubDate],[LastPubDate],[n] FROM '+ @SourceDBName + '.dbo.sna_coauthors'
	INSERT INTO [Profile.Cache].[SNA.Coauthor]([PersonID1],[PersonID2],[i],[j],[w],[FirstPubDate],[LastPubDate],[n] )
	EXEC sp_executesql @sql	    
	
	--	[profile.cache].[Concept.Mesh.Count]dbo.cache_mesh_count
	TRUNCATE TABLE [Profile.Cache].[Concept.Mesh.Count]
	SELECT @sql = 'SELECT[MeshHeader],[NumPublications],[NumFaculty],[Weight],[RawWeight] FROM '+ @SourceDBName + '.dbo.cache_mesh_count'
	INSERT INTO [Profile.Cache].[Concept.Mesh.Count]([MeshHeader],[NumPublications],[NumFaculty],[Weight],[RawWeight] )
	EXEC sp_executesql @sql	    
	 
	--	[Profile.Cache].[Person.PhysicalNeighbor]dbo.cache_physical_neighbors
	TRUNCATE TABLE [Profile.Cache].[Person.PhysicalNeighbor]
	SELECT @sql = 'SELECT[PersonID],[NeighborID],[Distance],[DisplayName],[MyNeighbors] FROM '+ @SourceDBName + '.dbo.cache_physical_neighbors'
	INSERT INTO [Profile.Cache].[Person.PhysicalNeighbor]([PersonID],[NeighborID],[Distance],[DisplayName],[MyNeighbors])
	EXEC sp_executesql @sql	    
	
	--	[Profile.Cache].[Person.SimilarPerson]dbo.cache_similar_people
	TRUNCATE TABLE [Profile.Cache].[Person.SimilarPerson]
	SELECT @sql = 'SELECT[PersonID],[SimilarPersonID],[Weight],[CoAuthor] FROM '+ @SourceDBName + '.dbo.cache_similar_people'
	INSERT INTO [Profile.Cache].[Person.SimilarPerson]([PersonID],[SimilarPersonID],[Weight],[CoAuthor])
	EXEC sp_executesql @sql	    
	
	--	[Profile.Cache].[Concept.Mesh.Person]dbo.cache_user_mesh
	TRUNCATE TABLE [Profile.Cache].[Concept.Mesh.Person]
	SELECT @sql = 'SELECT[PersonID],[MeshHeader],[NumPubsAll],[NumPubsThis],[Weight],[FirstPublicationYear],[LastPublicationYear],[MaxAuthorWeight],[WeightCategory]FROM '+ @SourceDBName + '.dbo.cache_user_mesh'
	INSERT INTO [Profile.Cache].[Concept.Mesh.Person]([PersonID],[MeshHeader],[NumPubsAll],[NumPubsThis],[Weight],[FirstPublicationYear],[LastPublicationYear],[MaxAuthorWeight],[WeightCategory])
	EXEC sp_executesql @sql	    
	
	--	[Profile.Data].[Publication.PubMed.General]dbo.pm_pubs_general
	DELETE FROM [Profile.Data].[Publication.PubMed.General]
	SELECT @sql = 'SELECT[PMID],[Owner],[Status],[PubModel],[Volume],[Issue],[MedlineDate],[JournalYear],[JournalMonth],[JournalDay],[JournalTitle],[ISOAbbreviation],[MedlineTA],[ArticleTitle],[MedlinePgn],[AbstractText],[ArticleDateType],[ArticleYear],[ArticleMonth],[ArticleDay],[Affiliation],[AuthorListCompleteYN],[GrantListCompleteYN],[PubDate],[Authors]FROM '+ @SourceDBName + '.dbo.pm_pubs_general'
	INSERT INTO [Profile.Data].[Publication.PubMed.General]([PMID],[Owner],[Status],[PubModel],[Volume],[Issue],[MedlineDate],[JournalYear],[JournalMonth],[JournalDay],[JournalTitle],[ISOAbbreviation],[MedlineTA],[ArticleTitle],[MedlinePgn],[AbstractText],[ArticleDateType],[ArticleYear],[ArticleMonth],[ArticleDay],[Affiliation],[AuthorListCompleteYN],[GrantListCompleteYN],[PubDate],[Authors])
	EXEC sp_executesql @sql	    
	
	--	[Profile.Data].[Publication.MyPub.General]dbo.my_pubs_general
	DELETE FROM [Profile.Data].[Publication.MyPub.General]
	SELECT @sql = 'SELECT[MPID],[PersonID],[PMID],[HmsPubCategory],[NlmPubCategory],[PubTitle],[ArticleTitle],[ArticleType],[ConfEditors],[ConfLoc],[EDITION],[PlaceOfPub],[VolNum],[PartVolPub],[IssuePub],[PaginationPub],[AdditionalInfo],[Publisher],[SecondaryAuthors],[ConfNm],[ConfDTs],[ReptNumber],[ContractNum],[DissUnivNm],[NewspaperCol],[NewspaperSect],[PublicationDT],[Abstract],[Authors],[URL],[CreatedDT],[CreatedBy],[UpdatedDT],[UpdatedBy] FROM '+ @SourceDBName + '.dbo.my_pubs_general'
	INSERT INTO [Profile.Data].[Publication.MyPub.General]([MPID],[PersonID],[PMID],[HmsPubCategory],[NlmPubCategory],[PubTitle],[ArticleTitle],[ArticleType],[ConfEditors],[ConfLoc],[EDITION],[PlaceOfPub],[VolNum],[PartVolPub],[IssuePub],[PaginationPub],[AdditionalInfo],[Publisher],[SecondaryAuthors],[ConfNm],[ConfDTs],[ReptNumber],[ContractNum],[DissUnivNm],[NewspaperCol],[NewspaperSect],[PublicationDT],[Abstract],[Authors],[URL],[CreatedDT],[CreatedBy],[UpdatedDT],[UpdatedBy] )
	EXEC sp_executesql @sql	    
	
	--	[Profile.Data].[Publication.PubMed.Mesh]
	DELETE FROM [Profile.Data].[Publication.PubMed.Mesh]
	SELECT @sql = 'SELECT [PMID],[descriptorname],[QualifierName],[MajorTopicYN] FROM '+ @SourceDBName + '.dbo.pm_pubs_mesh'
	INSERT INTO [Profile.Data].[Publication.PubMed.Mesh]( [PMID],[descriptorname],[QualifierName],[MajorTopicYN])
	EXEC sp_executesql @sql	 
	
	-- [Profile.Data].[Publication.PubMed.Accession]
	DELETE FROM [Profile.Data].[Publication.PubMed.Accession]
	SELECT @sql = 'SELECT [PMID],[DataBankName],[AccessionNumber]  FROM '+ @SourceDBName + '.dbo.pm_pubs_accessions'
	INSERT INTO [Profile.Data].[Publication.PubMed.accession]([PMID],[DataBankName],[AccessionNumber])
	EXEC sp_executesql @sql	 
	
	--1 [Profile.Data].[Publication.PubMed.Author]
	DELETE FROM [Profile.Data].[Publication.PubMed.Author]
	SELECT @sql = 'SELECT [PMID],[ValidYN],[LastName],FirstName,ForeName,Suffix,Initials,Affiliation  FROM '+ @SourceDBName + '.dbo.pm_pubs_authors'
	INSERT INTO [Profile.Data].[Publication.PubMed.Author]([PMID],[ValidYN],[LastName],FirstName,ForeName,Suffix,Initials,Affiliation)
	EXEC sp_executesql @sql	 
	
	 
	--1 [Profile.Data].[Publication.PubMed.Chemical]
	DELETE FROM [Profile.Data].[Publication.PubMed.Chemical]
	SELECT @sql = 'SELECT [PMID],NameOfSubstance  FROM '+ @SourceDBName + '.dbo.pm_pubs_chemicals'
	INSERT INTO [Profile.Data].[Publication.PubMed.Chemical]([PMID],NameOfSubstance)
	EXEC sp_executesql @sql	 
	
	 
	-- [Profile.Data].[Publication.PubMed.Databank]
	DELETE FROM [Profile.Data].[Publication.PubMed.Databank]
	SELECT @sql = 'SELECT [PMID],DataBankName  FROM '+ @SourceDBName + '.dbo.pm_pubs_databanks'
	INSERT INTO [Profile.Data].[Publication.PubMed.Databank]([PMID],DataBankName)
	EXEC sp_executesql @sql	 
	
	 
	--[Profile.Data].[Publication.PubMed.Grant]
	DELETE FROM [Profile.Data].[Publication.PubMed.Grant]
	SELECT @sql = 'SELECT [PMID],GrantID,Acronym,Agency  FROM '+ @SourceDBName + '.dbo.pm_pubs_grants'
	INSERT INTO [Profile.Data].[Publication.PubMed.Grant]([PMID],GrantID,Acronym,Agency )
	EXEC sp_executesql @sql	
	
	--[Profile.Data].[Publication.PubMed.Investigator]
	DELETE FROM [Profile.Data].[Publication.PubMed.Investigator]
	SELECT @sql = 'SELECT [PMID],[LastName],FirstName,ForeName,Suffix,Initials,Affiliation FROM '+ @SourceDBName + '.dbo.pm_pubs_investigators'
	INSERT INTO [Profile.Data].[Publication.PubMed.Investigator]([PMID],[LastName],FirstName,ForeName,Suffix,Initials,Affiliation)
	EXEC sp_executesql @sql	
	
	--[Profile.Data].[Publication.PubMed.Keyword]
	DELETE FROM [Profile.Data].[Publication.PubMed.Keyword]
	SELECT @sql = 'SELECT PMID, Keyword,MajorTopicYN  FROM '+ @SourceDBName + '.dbo.pm_pubs_keywords'
	INSERT INTO [Profile.Data].[Publication.PubMed.Keyword](PMID, Keyword,MajorTopicYN )
	EXEC sp_executesql @sql	 
	
	--	[Profile.Data].[Publication.Person.Include]dbo.publications_include
	TRUNCATE TABLE [Profile.Data].[Publication.Person.Include]
	SELECT @sql = 'SELECT[PubID],[PersonID],[PMID],[MPID] FROM '+ @SourceDBName + '.dbo.publications_include'
	INSERT INTO [Profile.Data].[Publication.Person.Include]([PubID],[PersonID],[PMID],[MPID])
	EXEC sp_executesql @sql	    
	
	--	[Profile.Data].[Publication.Person.Add]dbo.publications_add
	TRUNCATE TABLE [Profile.Data].[Publication.Person.Add]
	SELECT @sql = 'SELECT[PubID],[PersonID],[PMID],[MPID] FROM '+ @SourceDBName + '.dbo.publications_add'
	INSERT INTO [Profile.Data].[Publication.Person.Add]([PubID],[PersonID],[PMID],[MPID])
	EXEC sp_executesql @sql	   
	
	--	[Profile.Data].[Publication.Person.Exclude]dbo.publications_Exclude
	TRUNCATE TABLE [Profile.Data].[Publication.Person.Exclude]
	SELECT @sql = 'SELECT[PubID],[PersonID],[PMID],[MPID] FROM '+ @SourceDBName + '.dbo.publications_Exclude'
	INSERT INTO [Profile.Data].[Publication.Person.Exclude]([PubID],[PersonID],[PMID],[MPID])
	EXEC sp_executesql @sql	   
	
	--	[Profile.Data].[Publication.PubMed.AllXML]dbo.pm_all_xml
	TRUNCATE TABLE [Profile.Data].[Publication.PubMed.AllXML]
	SELECT @sql = 'SELECT pmid,x,parsedt FROM '+ @SourceDBName + '.dbo.pm_all_xml'
	INSERT INTO [Profile.Data].[Publication.PubMed.AllXML]([PMID],x,parsedt)
	EXEC sp_executesql @sql	   
	 
	--	[User.Account].[User]dbo.[user]
	SET IDENTITY_INSERT [User.Account].[User] ON 
	DELETE FROM [User.Account].[User]
	SELECT @sql = 'SELECT[UserID],EmailAddr,[PersonID],[IsActive],[CanBeProxy],[FirstName],[LastName],[DisplayName],[InstitutionFullName],[DepartmentFullName],[DivisionFullName],[UserName],[Password],[CreateDate],[ApplicationName],[Comment],[IsApproved],[IsOnline],[InternalUserName] FROM '+ @SourceDBName + '.dbo.[user] '
	INSERT INTO [User.Account].[User]([UserID],EmailAddr,[PersonID],[IsActive],[CanBeProxy],[FirstName],[LastName],[DisplayName],[Institution],[Department],[Division],[UserName],[Password],[CreateDate],[ApplicationName],[Comment],[IsApproved],[IsOnline],[InternalUserName])
	EXEC sp_executesql @sql	    
	SET IDENTITY_INSERT [User.Account].[User] OFF  
 
	--  [User.Account].DefaultProxy
	DELETE FROM [User.Account].DefaultProxy
	SELECT @sql = 'SELECT proxy, institution,department,NULL, case when ishidden=''Y'' then 0 else 1 end	FROM  '+ @SourceDBName + '.dbo.[proxies_default]  '
	INSERT INTO [User.Account].DefaultProxy
	        ( UserID ,
	          ProxyForInstitution ,
	          ProxyForDepartment ,
	          ProxyForDivision ,
	          IsVisible
	        )
	EXEC sp_executesql @sql	 
	
	-- [User.Account].DesignatedProxy 
	DELETE FROM [User.Account].DesignatedProxy 
	SELECT @sql = 'select  Proxy, PersonID FROM  '+ @SourceDBName + '.dbo.[proxies_designated]  '
	INSERT INTO [User.Account].DesignatedProxy ( UserID, ProxyForUserID )
	EXEC sp_executesql @sql 
	
	-- [User.Account].Relationship 
	DELETE FROM [User.Account].Relationship
	SELECT @sql = 'select UserID, personid,RelationshipType FROM  '+ @SourceDBName + '.dbo.[user_relationships]  '
	INSERT INTO [User.Account].Relationship ( UserID, personid,RelationshipType )
	EXEC sp_executesql @sql 
	 
	-- [Profile.Import].[Beta.DisplayPreference]
	TRUNCATE TABLE [Profile.Import].[Beta.DisplayPreference]
	SELECT @sql = 'select PersonID,ShowPhoto,ShowPublications,ShowAwards,ShowNarrative,ShowAddress,ShowEmail,ShowPhone,ShowFax,PhotoPreference FROM  '+ @SourceDBName + '.dbo.[display_prefs]  '
	INSERT INTO [Profile.Import].[Beta.DisplayPreference] (PersonID,ShowPhoto,ShowPublications,ShowAwards,ShowNarrative,ShowAddress,ShowEmail,ShowPhone,ShowFax,PhotoPreference )
	EXEC sp_executesql @sql 			
	
	-- [Profile.Data].[Person.Photo]
	TRUNCATE TABLE [Profile.Data].[Person.Photo]
	SELECT @sql = 'select PersonID,Photo,PhotoLink  FROM  '+ @SourceDBName + '.dbo.[photo]  '
	INSERT INTO [Profile.Data].[Person.Photo] (PersonID,Photo,PhotoLink )
	EXEC sp_executesql @sql 	
		
			 
	--  [Profile.Cache].[Concept.Mesh.SimilarConcept]
	TRUNCATE TABLE [Profile.Cache].[Concept.Mesh.SimilarConcept]
	SELECT @sql = 'SELECT meshheader, sortorder, similarconcept, weight FROM  '+ @SourceDBName + '.dbo.[cache_similar_concepts]  '
	INSERT INTO [Profile.Cache].[Concept.Mesh.SimilarConcept] (meshheader, sortorder, similarconcept, weight)
	EXEC sp_executesql @sql 
	
	-- [Profile.Cache].[SNA.Coauthor.Distance]
	TRUNCATE TABLE [Profile.Cache].[SNA.Coauthor.Distance]
	SELECT @sql = 'SELECT PersonID1,PersonID2,Distance,NumPaths FROM '+ @SourceDBName + '.dbo.sna_distance'
	INSERT INTO [Profile.Cache].[SNA.Coauthor.Distance] (PersonID1,PersonID2,Distance,NumPaths)
	EXEC sp_executesql @sql  
	
	-- [Profile.Cache].[SNA.Coauthor.Reach]
	TRUNCATE TABLE [Profile.Cache].[SNA.Coauthor.Reach]
	SELECT @sql = 'SELECT PersonID,Distance,NumPeople FROM '+ @SourceDBName + '.dbo.sna_reach'
	INSERT INTO [Profile.Cache].[SNA.Coauthor.Reach] (PersonID,Distance,NumPeople)
	EXEC sp_executesql @sql  
	
	-- [Profile.Cache].[SNA.Coauthor.Betweenness]
	TRUNCATE TABLE [Profile.Cache].[SNA.Coauthor.Betweenness]
	SELECT @sql = 'SELECT personid,i,b FROM '+ @SourceDBName + '.dbo.sna_betweenness'	
	INSERT INTO [Profile.Cache].[SNA.Coauthor.Betweenness] (personid,i,b)
	EXEC sp_executesql @sql 
				
  	-- [Profile.Data].[Publication.PubMed.DisambiguationAffiliation] 		
	truncate table [Profile.Data].[Publication.PubMed.DisambiguationAffiliation]
	SELECT @sql = 'SELECT affiliation FROM '+ @SourceDBName + '.dbo.disambiguation_pm_affiliations'	
	INSERT INTO [Profile.Data].[Publication.PubMed.DisambiguationAffiliation] (affiliation)
	EXEC sp_executesql @sql 		
	 
	-- Toggle off fkey constraints
	ALTER TABLE [Profile.Data].[Person.FilterRelationship]  CHECK CONSTRAINT FK_person_type_relationships_person
	ALTER TABLE [Profile.Data].[Person.FilterRelationship]  CHECK CONSTRAINT FK_person_type_relationships_person_types	
	ALTER TABLE [Profile.Data].[Publication.Person.Include]  CHECK CONSTRAINT FK_publications_include_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.MyPub.General]  CHECK CONSTRAINT FK_my_pubs_general_person
	ALTER TABLE [Profile.Data].[Publication.Person.Include]  CHECK CONSTRAINT FK_publications_include_person
	ALTER TABLE [Profile.Data].[Publication.Person.Include]  CHECK CONSTRAINT FK_publications_include_my_pubs_general 
	ALTER TABLE [Profile.Data].[Publication.PubMed.Accession]  CHECK CONSTRAINT  FK_pm_pubs_accessions_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Author]  CHECK CONSTRAINT  FK_pm_pubs_authors_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Chemical]  CHECK CONSTRAINT  FK_pm_pubs_chemicals_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Databank]   CHECK CONSTRAINT  FK_pm_pubs_databanks_pm_pubs_general
	ALTER TABLE [Profile.Data].[Publication.PubMed.Grant]  CHECK CONSTRAINT FK_pm_pubs_grants_pm_pubs_general
	
	-- Popluate [Publication.Entity.Authorship] and [Publication.Entity.InformationResource] tables
	EXEC [Profile.Data].[Publication.Entity.UpdateEntity]
 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Concept.Mesh.ParseMeshXML]'
GO
ALTER PROCEDURE [Profile.Data].[Concept.Mesh.ParseMeshXML]
AS
BEGIN
	SET NOCOUNT ON;

	-- Clear any existing data
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.XML]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.Descriptor]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.Qualifier]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.Term]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.SemanticType]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.SemanticGroupType]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.SemanticGroup]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.Tree]
	TRUNCATE TABLE [Profile.Data].[Concept.Mesh.TreeTop]

	-- Extract items from SemGroups.xml
	INSERT INTO [Profile.Data].[Concept.Mesh.SemanticGroupType] (SemanticGroupUI,SemanticGroupName,SemanticTypeUI,SemanticTypeName)
		SELECT 
			S.x.value('SemanticGroupUI[1]','varchar(10)'),
			S.x.value('SemanticGroupName[1]','varchar(50)'),
			S.x.value('SemanticTypeUI[1]','varchar(10)'),
			S.x.value('SemanticTypeName[1]','varchar(50)')
		FROM [Profile.Data].[Concept.Mesh.File] CROSS APPLY Data.nodes('//SemanticType') AS S(x)
		WHERE Name = 'SemGroups.xml'

	-- Extract items from MeSH2011.xml
	INSERT INTO [Profile.Data].[Concept.Mesh.XML] (DescriptorUI, MeSH)
		SELECT D.x.value('DescriptorUI[1]','varchar(10)'), D.x.query('.')
			FROM [Profile.Data].[Concept.Mesh.File] CROSS APPLY Data.nodes('//DescriptorRecord') AS D(x)
			WHERE Name = 'MeSH.xml'


	---------------------------------------
	-- Parse MeSH XML and populate tables
	---------------------------------------


	INSERT INTO [Profile.Data].[Concept.Mesh.Descriptor] (DescriptorUI, DescriptorName)
		SELECT DescriptorUI, MeSH.value('DescriptorRecord[1]/DescriptorName[1]/String[1]','varchar(255)')
			FROM [Profile.Data].[Concept.Mesh.XML]

	INSERT INTO [Profile.Data].[Concept.Mesh.Qualifier] (DescriptorUI, QualifierUI, DescriptorName, QualifierName, Abbreviation)
		SELECT	m.DescriptorUI,
				Q.x.value('QualifierReferredTo[1]/QualifierUI[1]','varchar(10)'),
				m.MeSH.value('DescriptorRecord[1]/DescriptorName[1]/String[1]','varchar(255)'),
				Q.x.value('QualifierReferredTo[1]/QualifierName[1]/String[1]','varchar(255)'),
				Q.x.value('Abbreviation[1]','varchar(2)')
			FROM [Profile.Data].[Concept.Mesh.XML] m CROSS APPLY MeSH.nodes('//AllowableQualifier') AS Q(x)

	SELECT	m.DescriptorUI,
			C.x.value('ConceptUI[1]','varchar(10)') ConceptUI,
			m.MeSH.value('DescriptorRecord[1]/DescriptorName[1]/String[1]','varchar(255)') DescriptorName,
			C.x.value('@PreferredConceptYN[1]','varchar(1)') PreferredConceptYN,
			C.x.value('ConceptRelationList[1]/ConceptRelation[1]/@RelationName[1]','varchar(3)') RelationName,
			C.x.value('ConceptName[1]/String[1]','varchar(255)') ConceptName,
			C.x.query('.') ConceptXML
		INTO #c
		FROM [Profile.Data].[Concept.Mesh.XML] m 
			CROSS APPLY MeSH.nodes('//Concept') AS C(x)

	INSERT INTO [Profile.Data].[Concept.Mesh.Term] (DescriptorUI, ConceptUI, TermUI, TermName, DescriptorName, PreferredConceptYN, RelationName, ConceptName, ConceptPreferredTermYN, IsPermutedTermYN, LexicalTag)
		SELECT	DescriptorUI,
				ConceptUI,
				T.x.value('TermUI[1]','varchar(10)'),
				T.x.value('String[1]','varchar(255)'),
				DescriptorName,
				PreferredConceptYN,
				RelationName,
				ConceptName,
				T.x.value('@ConceptPreferredTermYN[1]','varchar(1)'),
				T.x.value('@IsPermutedTermYN[1]','varchar(1)'),
				T.x.value('@LexicalTag[1]','varchar(3)')
			FROM #c C CROSS APPLY ConceptXML.nodes('//Term') AS T(x)

	INSERT INTO [Profile.Data].[Concept.Mesh.SemanticType] (DescriptorUI, SemanticTypeUI, SemanticTypeName)
		SELECT DISTINCT 
				m.DescriptorUI,
				S.x.value('SemanticTypeUI[1]','varchar(10)') SemanticTypeUI,
				S.x.value('SemanticTypeName[1]','varchar(50)') SemanticTypeName
			FROM [Profile.Data].[Concept.Mesh.XML] m 
				CROSS APPLY MeSH.nodes('//SemanticType') AS S(x)

	INSERT INTO [Profile.Data].[Concept.Mesh.SemanticGroup] (DescriptorUI, SemanticGroupUI, SemanticGroupName)
		SELECT DISTINCT t.DescriptorUI, g.SemanticGroupUI, g.SemanticGroupName
			FROM [Profile.Data].[Concept.Mesh.SemanticGroupType] g, [Profile.Data].[Concept.Mesh.SemanticType] t
			WHERE g.SemanticTypeUI = t.SemanticTypeUI

	INSERT INTO [Profile.Data].[Concept.Mesh.Tree] (DescriptorUI, TreeNumber)
		SELECT	m.DescriptorUI,
				T.x.value('.','varchar(255)')
			FROM [Profile.Data].[Concept.Mesh.XML] m 
				CROSS APPLY MeSH.nodes('//TreeNumber') AS T(x)

	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] (TreeNumber, DescriptorName)
		SELECT	T.x.value('.','varchar(255)'),
				m.MeSH.value('DescriptorRecord[1]/DescriptorName[1]/String[1]','varchar(255)')
			FROM [Profile.Data].[Concept.Mesh.XML] m 
				CROSS APPLY MeSH.nodes('//TreeNumber') AS T(x)
	UPDATE [Profile.Data].[Concept.Mesh.TreeTop]
		SET TreeNumber = left(TreeNumber,1)+'.'+TreeNumber
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('A','Anatomy')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('B','Organisms')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('C','Diseases')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('D','Chemicals and Drugs')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('E','Analytical, Diagnostic and Therapeutic Techniques and Equipment')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('F','Psychiatry and Psychology')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('G','Biological Sciences')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('H','Natural Sciences')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('I','Anthropology, Education, Sociology and Social Phenomena')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('J','Technology, Industry, Agriculture')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('K','Humanities')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('L','Information Science')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('M','Named Groups')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('N','Health Care')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('V','Publication Characteristics')
	INSERT INTO [Profile.Data].[Concept.Mesh.TreeTop] VALUES ('Z','Geographicals')

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.Pubmed.LoadDisambiguationResults]'
GO
ALTER procedure [Profile.Data].[Publication.Pubmed.LoadDisambiguationResults]
AS
BEGIN
BEGIN TRY  
BEGIN TRAN
 
-- Remove orphaned pubs
DELETE FROM [Profile.Data].[Publication.Person.Include]
	  WHERE NOT EXISTS (SELECT *
						  FROM [Profile.Data].[Publication.PubMed.Disambiguation] p
						 WHERE p.personid = [Profile.Data].[Publication.Person.Include].personid
						   AND p.pmid = [Profile.Data].[Publication.Person.Include].pmid)
		AND mpid IS NULL

-- Add Added Pubs
insert into [Profile.Data].[Publication.Person.Include](pubid,PersonID,pmid,mpid)
select PubID, PersonID, PMID, MPID from 
	[Profile.Data].[Publication.Person.Add]
	where PubID not in (select PubID from [Profile.Data].[Publication.Person.Include])
		
--Move in new pubs
INSERT INTO [Profile.Data].[Publication.Person.Include]
SELECT	 NEWID(),
		 personid,
		 pmid,
		 NULL
  FROM [Profile.Data].[Publication.PubMed.Disambiguation] d
 WHERE NOT EXISTS (SELECT *
					 FROM  [Profile.Data].[Publication.Person.Include] p
					WHERE p.personid = d.personid
					  AND p.pmid = d.pmid)
  AND EXISTS (SELECT 1 FROM [Profile.Data].[Publication.PubMed.General] g where g.pmid = d.pmid)					  
 
COMMIT
	END TRY
	BEGIN CATCH
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
 
		-- Raise an error with the details of the exception
		SELECT @ErrMsg =  ERROR_MESSAGE(),
					 @ErrSeverity = ERROR_SEVERITY()
 
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
			 
	END CATCH		
 
-- Popluate [Publication.Entity.Authorship] and [Publication.Entity.InformationResource] tables
	EXEC [Profile.Data].[Publication.Entity.UpdateEntity]
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Publication.Pubmed.AddPublication]'
GO
ALTER procedure [Profile.Data].[Publication.Pubmed.AddPublication] 
	@UserID INT,
	@pmid int
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
 
	if exists (select * from [Profile.Data].[Publication.PubMed.AllXML] where pmid = @pmid)
	begin
 
		declare @ParseDate datetime
		set @ParseDate = (select coalesce(ParseDT,'1/1/1900') from [Profile.Data].[Publication.PubMed.AllXML] where pmid = @pmid)
		if (@ParseDate < '1/1/2000')
		begin
			exec [Profile.Data].[Publication.Pubmed.ParsePubMedXML] 
			 @pmid
		end
 BEGIN TRY 
		BEGIN TRANSACTION
 
			if not exists (select * from [Profile.Data].[Publication.Person.Include] where PersonID = @UserID and pmid = @pmid)
			begin
 
				declare @pubid uniqueidentifier
				declare @mpid varchar(50)
 
				set @mpid = null
 
				set @pubid = (select top 1 pubid from [Profile.Data].[Publication.Person.Exclude] where PersonID = @UserID and pmid = @pmid)
				if @pubid is not null
					begin
						set @mpid = (select mpid from [Profile.Data].[Publication.Person.Exclude] where pubid = @pubid)
						delete from [Profile.Data].[Publication.Person.Exclude] where pubid = @pubid
					end
				else
					begin
						set @pubid = (select newid())
					end
 
				insert into [Profile.Data].[Publication.Person.Include](pubid,PersonID,pmid,mpid)
					values (@pubid,@UserID,@pmid,@mpid)
 
				insert into [Profile.Data].[Publication.Person.Add](pubid,PersonID,pmid,mpid)
					values (@pubid,@UserID,@pmid,@mpid)
					
				insert into [Profile.Data].[Publication.PubMed.Disambiguation] (PersonID, PMID)
					values (@UserID, @pmid)
 
				EXEC  [Profile.Data].[Publication.Pubmed.AddOneAuthorPosition] @PersonID = @UserID, @pmid = @pmid
 
				-- Popluate [Publication.Entity.Authorship] and [Publication.Entity.InformationResource] tables
				EXEC [Profile.Data].[Publication.Entity.UpdateEntityOnePerson]@UserID
				
			end
 
		COMMIT TRANSACTION
	END TRY
	BEGIN CATCH
		DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
 
		-- Raise an error with the details of the exception
		SELECT @ErrMsg =  ERROR_MESSAGE(),
					 @ErrSeverity = ERROR_SEVERITY()
 
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
			 
	END CATCH		
 
	END
 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Data].[Concept.Mesh.GetJournals]'
GO
ALTER PROCEDURE [Profile.Data].[Concept.Mesh.GetJournals]
	@NodeID BIGINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @DescriptorName NVARCHAR(255)
 	SELECT @DescriptorName = d.DescriptorName
		FROM [RDF.Stage].[InternalNodeMap] m, [RDF.].Node n,
			[Profile.Data].[Concept.Mesh.Descriptor] d
		WHERE m.Status = 3 AND m.ValueHash = n.ValueHash AND n.NodeID = @NodeID
			AND m.InternalID = d.DescriptorUI

	select top 10 Journal, JournalTitle, Weight, NumJournals TotalRecords
		from [Profile.Cache].[Concept.Mesh.Journal]
		where meshheader = @DescriptorName
		order by Weight desc

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Cache].[Concept.Mesh.TreeTop]'
GO
CREATE TABLE [Profile.Cache].[Concept.Mesh.TreeTop]
(
[FullTreeNumber] [varchar] (255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
[ParentTreeNumber] [varchar] (255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
[TreeNumber] [varchar] (255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
[DescriptorName] [varchar] (255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
[DescriptorUI] [varchar] (10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
)
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating primary key [PK__Concept.Mesh.Tre__6754599E] on [Profile.Cache].[Concept.Mesh.TreeTop]'
GO
ALTER TABLE [Profile.Cache].[Concept.Mesh.TreeTop] ADD PRIMARY KEY CLUSTERED  ([FullTreeNumber])
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating index [idx_p] on [Profile.Cache].[Concept.Mesh.TreeTop]'
GO
CREATE NONCLUSTERED INDEX [idx_p] ON [Profile.Cache].[Concept.Mesh.TreeTop] ([ParentTreeNumber])
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating index [idx_d] on [Profile.Cache].[Concept.Mesh.TreeTop]'
GO
CREATE NONCLUSTERED INDEX [idx_d] ON [Profile.Cache].[Concept.Mesh.TreeTop] ([DescriptorUI])
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Data].[Concept.Mesh.GetDescriptorXML]'
GO
CREATE PROCEDURE [Profile.Data].[Concept.Mesh.GetDescriptorXML]
	@NodeID BIGINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


	declare @baseURI nvarchar(400)
	select @baseURI = value from [Framework.].Parameter where ParameterID = 'baseURI'


	------------------------------------------------------------
	-- Convert the NodeID to a DescriptorUI
	------------------------------------------------------------

	DECLARE @DescriptorUI VARCHAR(50)
	SELECT @DescriptorUI = m.InternalID
		FROM [RDF.Stage].[InternalNodeMap] m, [RDF.].Node n
		WHERE m.Status = 3 AND m.ValueHash = n.ValueHash AND n.NodeID = @NodeID
 
	IF @DescriptorUI IS NULL
	BEGIN
		SELECT cast(null as xml) DescriptorXML WHERE 1=0
		RETURN
	END


	------------------------------------------------------------
	-- Combine MeSH tables
	------------------------------------------------------------
	/*
	select r.TreeNumber FullTreeNumber, 
			(case when len(r.TreeNumber)=1 then '' else left(r.TreeNumber,len(r.TreeNumber)-4) end) ParentTreeNumber,
			r.DescriptorName, IsNull(t.TreeNumber,r.TreeNumber) TreeNumber, t.DescriptorUI, m.NodeID, f.Value+cast(m.NodeID as varchar(50)) NodeURI
		into #m
		from [Profile.Data].[Concept.Mesh.TreeTop] r
			left outer join [Profile.Data].[Concept.Mesh.Tree] t
				on t.TreeNumber = substring(r.TreeNumber,3,999)
			left outer join [RDF.Stage].[InternalNodeMap] m
				on m.Class = 'http://www.w3.org/2004/02/skos/core#Concept'
					and m.InternalType = 'MeshDescriptor'
					and m.InternalID = cast(t.DescriptorUI as varchar(50))
					and t.DescriptorUI is not null
					and m.Status = 3
			left outer join [Framework.].[Parameter] f
				on f.ParameterID = 'baseURI'
	
	create unique clustered index idx_f on #m(FullTreeNumber)
	create nonclustered index idx_d on #m(DescriptorUI)
	create nonclustered index idx_p on #m(ParentTreeNumber)
	*/

	------------------------------------------------------------
	-- Construct the DescriptorXML
	------------------------------------------------------------

	;with p0 as (
		select distinct b.*
		from [Profile.Cache].[Concept.Mesh.TreeTop] a, [Profile.Cache].[Concept.Mesh.TreeTop] b
		where a.DescriptorUI = @DescriptorUI
			and a.FullTreeNumber like b.FullTreeNumber+'%'
	), r0 as (
		select c.*, b.DescriptorName ParentName, 2 Depth
			from [Profile.Cache].[Concept.Mesh.TreeTop] a, [Profile.Cache].[Concept.Mesh.TreeTop] b, [Profile.Cache].[Concept.Mesh.TreeTop] c
			where a.DescriptorUI = @DescriptorUI
				and a.ParentTreeNumber = b.FullTreeNumber
				and c.ParentTreeNumber = b.FullTreeNumber
		union all
		select b.*, b.DescriptorName ParentName, 1 Depth
			from [Profile.Cache].[Concept.Mesh.TreeTop] a, [Profile.Cache].[Concept.Mesh.TreeTop] b
			where a.DescriptorUI = @DescriptorUI
				and a.ParentTreeNumber = b.FullTreeNumber
	), r1 as (
		select *
		from (
			select *, row_number() over (partition by DescriptorName, ParentName order by TreeNumber) k
			from r0
		) t
		where k = 1
	), c0 as (
		select top 1 DescriptorUI, TreeNumber, DescriptorName,FullTreeNumber
		from [Profile.Cache].[Concept.Mesh.TreeTop]
		where DescriptorUI = @DescriptorUI
		order by FullTreeNumber
	), c1 as (
		select b.DescriptorUI, b.TreeNumber, b.DescriptorName, 2 Depth
			from c0 a, [Profile.Cache].[Concept.Mesh.TreeTop] b
			where b.ParentTreeNumber = a.FullTreeNumber
		union all
		select DescriptorUI, TreeNumber, DescriptorName, 1 Depth
			from c0
	)
	select (
			select
				(
					select MeSH
					from [Profile.Data].[Concept.Mesh.XML]
					where DescriptorUI = @DescriptorUI
					for xml path(''), type
				).query('MeSH[1]/*'),
				(
					select DescriptorUI, TreeNumber, DescriptorName,
						len(FullTreeNumber)-len(replace(FullTreeNumber,'.',''))+1 Depth,
						m.NodeID, @baseURI+cast(m.NodeID as varchar(50)) NodeURI,
						row_number() over (order by FullTreeNumber) SortOrder
					from p0 x
						left outer join [RDF.Stage].[InternalNodeMap] m
							on m.Class = 'http://www.w3.org/2004/02/skos/core#Concept'
								and m.InternalType = 'MeshDescriptor'
								and m.InternalID = x.DescriptorUI
								and x.DescriptorUI is not null
								and m.Status = 3
					for xml path('Descriptor'), type
				) ParentDescriptors,
				(
					select DescriptorUI, TreeNumber, DescriptorName, Depth,
						m.NodeID, @baseURI+cast(m.NodeID as varchar(50)) NodeURI,
						row_number() over (order by ParentName, Depth, DescriptorName) SortOrder
					from r1 x
						left outer join [RDF.Stage].[InternalNodeMap] m
							on m.Class = 'http://www.w3.org/2004/02/skos/core#Concept'
								and m.InternalType = 'MeshDescriptor'
								and m.InternalID = x.DescriptorUI
								and x.DescriptorUI is not null
								and m.Status = 3
					for xml path('Descriptor'), type
				) SiblingDescriptors,
				(
					select DescriptorUI, TreeNumber, DescriptorName, Depth,
						m.NodeID, @baseURI+cast(m.NodeID as varchar(50)) NodeURI,
						row_number() over (order by Depth, DescriptorName) SortOrder
					from c1 x
						left outer join [RDF.Stage].[InternalNodeMap] m
							on m.Class = 'http://www.w3.org/2004/02/skos/core#Concept'
								and m.InternalType = 'MeshDescriptor'
								and m.InternalID = x.DescriptorUI
								and x.DescriptorUI is not null
								and m.Status = 3
					where (select count(*) from c1) > 1
					for xml path('Descriptor'), type
				) ChildDescriptors
			for xml path('DescriptorXML'), type
		) as DescriptorXML


END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Search.Cache].[Public.GetNodes]'
GO
ALTER PROCEDURE [Search.Cache].[Public.GetNodes]
	@SearchOptions XML,
	@SessionID UNIQUEIDENTIFIER = NULL
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
		-- interfering with SELECT statements.
		SET NOCOUNT ON;

	/*
	
	EXEC [Search.].[GetNodes] @SearchOptions = '
	<SearchOptions>
		<MatchOptions>
			<SearchString ExactMatch="false">options for "lung cancer" treatment</SearchString>
			<ClassURI>http://xmlns.com/foaf/0.1/Person</ClassURI>
			<SearchFiltersList>
				<SearchFilter Property="http://xmlns.com/foaf/0.1/lastName" MatchType="Left">Smit</SearchFilter>
			</SearchFiltersList>
		</MatchOptions>
		<OutputOptions>
			<Offset>0</Offset>
			<Limit>5</Limit>
			<SortByList>
				<SortBy IsDesc="1" Property="http://xmlns.com/foaf/0.1/firstName" />
				<SortBy IsDesc="0" Property="http://xmlns.com/foaf/0.1/lastName" />
			</SortByList>
		</OutputOptions>	
	</SearchOptions>
	'
		
	*/

	declare @MatchOptions xml
	declare @OutputOptions xml
	declare @SearchString varchar(500)
	declare @ClassGroupURI varchar(400)
	declare @ClassURI varchar(400)
	declare @SearchFiltersXML xml
	declare @offset bigint
	declare @limit bigint
	declare @SortByXML xml
	declare @DoExpandedSearch bit
	
	select	@MatchOptions = @SearchOptions.query('SearchOptions[1]/MatchOptions[1]'),
			@OutputOptions = @SearchOptions.query('SearchOptions[1]/OutputOptions[1]')
	
	select	@SearchString = @MatchOptions.value('MatchOptions[1]/SearchString[1]','varchar(500)'),
			@DoExpandedSearch = (case when @MatchOptions.value('MatchOptions[1]/SearchString[1]/@ExactMatch','varchar(50)') = 'true' then 0 else 1 end),
			@ClassGroupURI = @MatchOptions.value('MatchOptions[1]/ClassGroupURI[1]','varchar(400)'),
			@ClassURI = @MatchOptions.value('MatchOptions[1]/ClassURI[1]','varchar(400)'),
			@SearchFiltersXML = @MatchOptions.query('MatchOptions[1]/SearchFiltersList[1]'),
			@offset = @OutputOptions.value('OutputOptions[1]/Offset[1]','bigint'),
			@limit = @OutputOptions.value('OutputOptions[1]/Limit[1]','bigint'),
			@SortByXML = @OutputOptions.query('OutputOptions[1]/SortByList[1]')

	declare @baseURI nvarchar(400)
	select @baseURI = value from [Framework.].Parameter where ParameterID = 'baseURI'

	declare @d datetime
	select @d = GetDate()
	
	declare @IsBot bit
	if @SessionID is not null
		select @IsBot = IsBot
			from [User.Session].[Session]
			where SessionID = @SessionID
	select @IsBot = IsNull(@IsBot,0)
	
	declare @SearchHistoryQueryID int
	insert into [Search.].[History.Query] (StartDate, SessionID, IsBot, SearchOptions)
		select GetDate(), @SessionID, @IsBot, @SearchOptions
	select @SearchHistoryQueryID = @@IDENTITY

	-------------------------------------------------------
	-- Parse search string and convert to fulltext query
	-------------------------------------------------------

	declare @NumberOfPhrases INT
	declare @CombinedSearchString VARCHAR(8000)
	declare @SearchPhraseXML XML
	declare @SearchPhraseFormsXML XML
	declare @ParseProcessTime INT

	EXEC [Search.].[ParseSearchString]	@SearchString = @SearchString,
										@NumberOfPhrases = @NumberOfPhrases OUTPUT,
										@CombinedSearchString = @CombinedSearchString OUTPUT,
										@SearchPhraseXML = @SearchPhraseXML OUTPUT,
										@SearchPhraseFormsXML = @SearchPhraseFormsXML OUTPUT,
										@ProcessTime = @ParseProcessTime OUTPUT

	declare @PhraseList table (PhraseID int, Phrase varchar(max), ThesaurusMatch bit, Forms varchar(max))
	insert into @PhraseList (PhraseID, Phrase, ThesaurusMatch, Forms)
	select	x.value('@ID','INT'),
			x.value('.','VARCHAR(MAX)'),
			x.value('@ThesaurusMatch','BIT'),
			x.value('@Forms','VARCHAR(MAX)')
		from @SearchPhraseFormsXML.nodes('//SearchPhrase') as p(x)

	--SELECT @NumberOfPhrases, @CombinedSearchString, @SearchPhraseXML, @SearchPhraseFormsXML, @ParseProcessTime
	--SELECT * FROM @PhraseList
	--select datediff(ms,@d,GetDate())


	-------------------------------------------------------
	-- Parse search filters
	-------------------------------------------------------

	create table #SearchFilters (
		SearchFilterID int identity(0,1) primary key,
		IsExclude bit,
		PropertyURI varchar(400),
		PropertyURI2 varchar(400),
		MatchType varchar(100),
		Value varchar(750),
		Predicate bigint,
		Predicate2 bigint
	)
	
	insert into #SearchFilters (IsExclude, PropertyURI, PropertyURI2, MatchType, Value, Predicate, Predicate2)	
		select t.IsExclude, t.PropertyURI, t.PropertyURI2, t.MatchType, t.Value,
				--left(t.Value,750)+(case when t.MatchType='Left' then '%' else '' end),
				t.Predicate, t.Predicate2
			from (
				select IsNull(IsExclude,0) IsExclude, PropertyURI, PropertyURI2, MatchType, Value,
					[RDF.].fnURI2NodeID(PropertyURI) Predicate,
					[RDF.].fnURI2NodeID(PropertyURI2) Predicate2
				from (
					select distinct S.x.value('@IsExclude','bit') IsExclude,
							S.x.value('@Property','varchar(400)') PropertyURI,
							S.x.value('@Property2','varchar(400)') PropertyURI2,
							S.x.value('@MatchType','varchar(100)') MatchType,
							--S.x.value('.','nvarchar(max)') Value
							(case when cast(S.x.query('./*') as nvarchar(max)) <> '' then cast(S.x.query('./*') as nvarchar(max)) else S.x.value('.','nvarchar(max)') end) Value
					from @SearchFiltersXML.nodes('//SearchFilter') as S(x)
				) t
			) t
			where t.Value IS NOT NULL and t.Value <> ''
			
	declare @NumberOfIncludeFilters int
	select @NumberOfIncludeFilters = IsNull((select count(*) from #SearchFilters where IsExclude=0),0)

	-------------------------------------------------------
	-- Parse sort by options
	-------------------------------------------------------

	create table #SortBy (
		SortByID int identity(1,1) primary key,
		IsDesc bit,
		PropertyURI varchar(400),
		PropertyURI2 varchar(400),
		PropertyURI3 varchar(400),
		Predicate bigint,
		Predicate2 bigint,
		Predicate3 bigint
	)
	
	insert into #SortBy (IsDesc, PropertyURI, PropertyURI2, PropertyURI3, Predicate, Predicate2, Predicate3)	
		select IsNull(IsDesc,0), PropertyURI, PropertyURI2, PropertyURI3,
				[RDF.].fnURI2NodeID(PropertyURI) Predicate,
				[RDF.].fnURI2NodeID(PropertyURI2) Predicate2,
				[RDF.].fnURI2NodeID(PropertyURI3) Predicate3
			from (
				select S.x.value('@IsDesc','bit') IsDesc,
						S.x.value('@Property','varchar(400)') PropertyURI,
						S.x.value('@Property2','varchar(400)') PropertyURI2,
						S.x.value('@Property3','varchar(400)') PropertyURI3
				from @SortByXML.nodes('//SortBy') as S(x)
			) t

	-------------------------------------------------------
	-- Get initial list of matching nodes (before filters)
	-------------------------------------------------------

	create table #FullNodeMatch (
		NodeID bigint not null,
		Paths bigint,
		Weight float
	)

	if @CombinedSearchString <> ''
	begin

		-- Get nodes that match separate phrases
		create table #PhraseNodeMatch (
			PhraseID int not null,
			NodeID bigint not null,
			Paths bigint,
			Weight float
		)
		if (@NumberOfPhrases > 1) and (@DoExpandedSearch = 1)
		begin
			declare @PhraseSearchString varchar(8000)
			declare @loop int
			select @loop = 1
			while @loop <= @NumberOfPhrases
			begin
				select @PhraseSearchString = Forms
					from @PhraseList
					where PhraseID = @loop
				insert into #PhraseNodeMatch (PhraseID, NodeID, Paths, Weight)
					select @loop, s.NodeID, count(*) Paths, 1-exp(sum(log(case when s.Weight*m.Weight > 0.999999 then 0.000001 else 1-s.Weight*m.Weight end))) Weight
						from [Search.Cache].[Public.NodeMap] s, (
							select [Key] NodeID, [Rank]*0.001 Weight
								from Containstable ([RDF.].Node, value, @PhraseSearchString) n
						) m
						where s.MatchedByNodeID = m.NodeID
						group by s.NodeID
				select @loop = @loop + 1
			end
			--create clustered index idx_n on #PhraseNodeMatch(NodeID)
		end

		create table #TempMatchNodes (
			NodeID bigint,
			MatchedByNodeID bigint,
			Distance int,
			Paths int,
			Weight float,
			mWeight float
		)
		insert into #TempMatchNodes (NodeID, MatchedByNodeID, Distance, Paths, Weight, mWeight)
			select s.*, m.Weight mWeight
				from [Search.Cache].[Public.NodeMap] s, (
					select [Key] NodeID, [Rank]*0.001 Weight
						from Containstable ([RDF.].Node, value, @CombinedSearchString) n
				) m
				where s.MatchedByNodeID = m.NodeID

		insert into #FullNodeMatch (NodeID, Paths, Weight)
			select IsNull(a.NodeID,b.NodeID) NodeID, IsNull(a.Paths,b.Paths) Paths,
					(case when a.weight is null or b.weight is null then IsNull(a.Weight,b.Weight) else 1-(1-a.Weight)*(1-b.Weight) end) Weight
				from (
					select NodeID, exp(sum(log(Paths))) Paths, exp(sum(log(Weight))) Weight
						from #PhraseNodeMatch
						group by NodeID
						having count(*) = @NumberOfPhrases
				) a full outer join (
					select NodeID, count(*) Paths, 1-exp(sum(log(case when Weight*mWeight > 0.999999 then 0.000001 else 1-Weight*mWeight end))) Weight
						from #TempMatchNodes
						group by NodeID
				) b on a.NodeID = b.NodeID
		--select 'Text Matches Found', datediff(ms,@d,getdate())
	end
	else if (@NumberOfIncludeFilters > 0)
	begin
		insert into #FullNodeMatch (NodeID, Paths, Weight)
			select t1.Subject, 1, 1
				from #SearchFilters f
					inner join [RDF.].Triple t1
						on f.Predicate is not null
							and t1.Predicate = f.Predicate 
							and t1.ViewSecurityGroup = -1
					left outer join [Search.Cache].[Public.NodePrefix] n1
						on n1.NodeID = t1.Object
					left outer join [RDF.].Triple t2
						on f.Predicate2 is not null
							and t2.Subject = n1.NodeID
							and t2.Predicate = f.Predicate2
							and t2.ViewSecurityGroup = -1
					left outer join [Search.Cache].[Public.NodePrefix] n2
						on n2.NodeID = t2.Object
				where f.IsExclude = 0
					and 1 = (case	when (f.Predicate2 is not null) then
										(case	when f.MatchType = 'Left' then
													(case when n2.Prefix like f.Value+'%' then 1 else 0 end)
												when f.MatchType = 'In' then
													(case when n2.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
												else
													(case when n2.Prefix = f.Value then 1 else 0 end)
												end)
									else
										(case	when f.MatchType = 'Left' then
													(case when n1.Prefix like f.Value+'%' then 1 else 0 end)
												when f.MatchType = 'In' then
													(case when n1.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
												else
													(case when n1.Prefix = f.Value then 1 else 0 end)
												end)
									end)
					--and (case when f.Predicate2 is not null then n2.Prefix else n1.Prefix end)
					--	like f.Value
				group by t1.Subject
				having count(distinct f.SearchFilterID) = @NumberOfIncludeFilters
		delete from #SearchFilters where IsExclude = 0
		select @NumberOfIncludeFilters = 0
	end
	else if (IsNull(@ClassGroupURI,'') <> '' or IsNull(@ClassURI,'') <> '')
	begin
		insert into #FullNodeMatch (NodeID, Paths, Weight)
			select distinct n.NodeID, 1, 1
				from [Search.Cache].[Public.NodeClass] n, [Ontology.].ClassGroupClass c
				where n.Class = c._ClassNode
					and ((@ClassGroupURI is null) or (c.ClassGroupURI = @ClassGroupURI))
					and ((@ClassURI is null) or (c.ClassURI = @ClassURI))
		select @ClassGroupURI = null, @ClassURI = null
	end

	-------------------------------------------------------
	-- Run the actual search
	-------------------------------------------------------
	create table #Node (
		SortOrder bigint identity(0,1) primary key,
		NodeID bigint,
		Paths bigint,
		Weight float
	)

	insert into #Node (NodeID, Paths, Weight)
		select s.NodeID, s.Paths, s.Weight
			from #FullNodeMatch s
				inner join [Search.Cache].[Public.NodeSummary] n on
					s.NodeID = n.NodeID
					and ( IsNull(@ClassGroupURI,@ClassURI) is null or s.NodeID in (
							select NodeID
								from [Search.Cache].[Public.NodeClass] x, [Ontology.].ClassGroupClass c
								where x.Class = c._ClassNode
									and c.ClassGroupURI = IsNull(@ClassGroupURI,c.ClassGroupURI)
									and c.ClassURI = IsNull(@ClassURI,c.ClassURI)
						) )
					and ( @NumberOfIncludeFilters =
							(select count(distinct f.SearchFilterID)
								from #SearchFilters f
									inner join [RDF.].Triple t1
										on f.Predicate is not null
											and t1.Subject = s.NodeID
											and t1.Predicate = f.Predicate 
											and t1.ViewSecurityGroup = -1
									left outer join [Search.Cache].[Public.NodePrefix] n1
										on n1.NodeID = t1.Object
									left outer join [RDF.].Triple t2
										on f.Predicate2 is not null
											and t2.Subject = n1.NodeID
											and t2.Predicate = f.Predicate2
											and t2.ViewSecurityGroup = -1
									left outer join [Search.Cache].[Public.NodePrefix] n2
										on n2.NodeID = t2.Object
								where f.IsExclude = 0
									and 1 = (case	when (f.Predicate2 is not null) then
														(case	when f.MatchType = 'Left' then
																	(case when n2.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n2.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n2.Prefix = f.Value then 1 else 0 end)
																end)
													else
														(case	when f.MatchType = 'Left' then
																	(case when n1.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n1.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n1.Prefix = f.Value then 1 else 0 end)
																end)
													end)
									--and (case when f.Predicate2 is not null then n2.Prefix else n1.Prefix end)
									--	like f.Value
							)
						)
					and not exists (
							select *
								from #SearchFilters f
									inner join [RDF.].Triple t1
										on f.Predicate is not null
											and t1.Subject = s.NodeID
											and t1.Predicate = f.Predicate 
											and t1.ViewSecurityGroup = -1
									left outer join [Search.Cache].[Public.NodePrefix] n1
										on n1.NodeID = t1.Object
									left outer join [RDF.].Triple t2
										on f.Predicate2 is not null
											and t2.Subject = n1.NodeID
											and t2.Predicate = f.Predicate2
											and t2.ViewSecurityGroup = -1
									left outer join [Search.Cache].[Public.NodePrefix] n2
										on n2.NodeID = t2.Object
								where f.IsExclude = 1
									and 1 = (case	when (f.Predicate2 is not null) then
														(case	when f.MatchType = 'Left' then
																	(case when n2.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n2.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n2.Prefix = f.Value then 1 else 0 end)
																end)
													else
														(case	when f.MatchType = 'Left' then
																	(case when n1.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n1.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n1.Prefix = f.Value then 1 else 0 end)
																end)
													end)
									--and (case when f.Predicate2 is not null then n2.Prefix else n1.Prefix end)
									--	like f.Value
						)
				outer apply (
					select	max(case when SortByID=1 then AscSortBy else null end) AscSortBy1,
							max(case when SortByID=2 then AscSortBy else null end) AscSortBy2,
							max(case when SortByID=3 then AscSortBy else null end) AscSortBy3,
							max(case when SortByID=1 then DescSortBy else null end) DescSortBy1,
							max(case when SortByID=2 then DescSortBy else null end) DescSortBy2,
							max(case when SortByID=3 then DescSortBy else null end) DescSortBy3
						from (
							select	SortByID,
									(case when f.IsDesc = 1 then null
											when f.Predicate3 is not null then n3.Value
											when f.Predicate2 is not null then n2.Value
											else n1.Value end) AscSortBy,
									(case when f.IsDesc = 0 then null
											when f.Predicate3 is not null then n3.Value
											when f.Predicate2 is not null then n2.Value
											else n1.Value end) DescSortBy
								from #SortBy f
									inner join [RDF.].Triple t1
										on f.Predicate is not null
											and t1.Subject = s.NodeID
											and t1.Predicate = f.Predicate 
											and t1.ViewSecurityGroup = -1
									left outer join [RDF.].Node n1
										on n1.NodeID = t1.Object
											and n1.ViewSecurityGroup = -1
									left outer join [RDF.].Triple t2
										on f.Predicate2 is not null
											and t2.Subject = n1.NodeID
											and t2.Predicate = f.Predicate2
											and t2.ViewSecurityGroup = -1
									left outer join [RDF.].Node n2
										on n2.NodeID = t2.Object
											and n2.ViewSecurityGroup = -1
									left outer join [RDF.].Triple t3
										on f.Predicate3 is not null
											and t3.Subject = n2.NodeID
											and t3.Predicate = f.Predicate3
											and t3.ViewSecurityGroup = -1
									left outer join [RDF.].Node n3
										on n3.NodeID = t3.Object
											and n3.ViewSecurityGroup = -1
							) t
					) o
			order by	(case when o.AscSortBy1 is null then 1 else 0 end),
						o.AscSortBy1,
						(case when o.DescSortBy1 is null then 1 else 0 end),
						o.DescSortBy1 desc,
						(case when o.AscSortBy2 is null then 1 else 0 end),
						o.AscSortBy2,
						(case when o.DescSortBy2 is null then 1 else 0 end),
						o.DescSortBy2 desc,
						(case when o.AscSortBy3 is null then 1 else 0 end),
						o.AscSortBy3,
						(case when o.DescSortBy3 is null then 1 else 0 end),
						o.DescSortBy3 desc,
						s.Weight desc,
						n.ShortLabel,
						n.NodeID


	--select 'Search Nodes Found', datediff(ms,@d,GetDate())

	-------------------------------------------------------
	-- Get network counts
	-------------------------------------------------------

	declare @NumberOfConnections as bigint
	declare @MaxWeight as float
	declare @MinWeight as float

	select @NumberOfConnections = count(*), @MaxWeight = max(Weight), @MinWeight = min(Weight) 
		from #Node

	-------------------------------------------------------
	-- Get matching class groups and classes
	-------------------------------------------------------

	declare @MatchesClassGroups nvarchar(max)

	select c.ClassGroupURI, c.ClassURI, n.NodeID
		into #NodeClass
		from #Node n, [Search.Cache].[Public.NodeClass] s, [Ontology.].ClassGroupClass c
		where n.NodeID = s.NodeID and s.Class = c._ClassNode

	;with a as (
		select ClassGroupURI, count(distinct NodeID) NumberOfNodes
			from #NodeClass s
			group by ClassGroupURI
	), b as (
		select ClassGroupURI, ClassURI, count(distinct NodeID) NumberOfNodes
			from #NodeClass s
			group by ClassGroupURI, ClassURI
	)
	select @MatchesClassGroups = replace(cast((
			select	g.ClassGroupURI "@rdf_.._resource", 
				g._ClassGroupLabel "rdfs_.._label",
				'http://www.w3.org/2001/XMLSchema#int' "prns_.._numberOfConnections/@rdf_.._datatype",
				a.NumberOfNodes "prns_.._numberOfConnections",
				g.SortOrder "prns_.._sortOrder",
				(
					select	c.ClassURI "@rdf_.._resource",
							c._ClassLabel "rdfs_.._label",
							'http://www.w3.org/2001/XMLSchema#int' "prns_.._numberOfConnections/@rdf_.._datatype",
							b.NumberOfNodes "prns_.._numberOfConnections",
							c.SortOrder "prns_.._sortOrder"
						from b, [Ontology.].ClassGroupClass c
						where b.ClassGroupURI = c.ClassGroupURI and b.ClassURI = c.ClassURI
							and c.ClassGroupURI = g.ClassGroupURI
						order by c.SortOrder
						for xml path('prns_.._matchesClass'), type
				)
			from a, [Ontology.].ClassGroup g
			where a.ClassGroupURI = g.ClassGroupURI and g.IsVisible = 1
			order by g.SortOrder
			for xml path('prns_.._matchesClassGroup'), type
		) as nvarchar(max)),'_.._',':')

	-------------------------------------------------------
	-- Get RDF of search results objects
	-------------------------------------------------------

	declare @ObjectNodesRDF nvarchar(max)

	if @NumberOfConnections > 0
	begin
		/*
			-- Alternative methods that uses GetDataRDF to get the RDF
			declare @NodeListXML xml
			select @NodeListXML = (
					select (
							select NodeID "@ID"
							from #Node
							where SortOrder >= IsNull(@offset,0) and SortOrder < IsNull(IsNull(@offset,0)+@limit,SortOrder+1)
							order by SortOrder
							for xml path('Node'), type
							)
					for xml path('NodeList'), type
				)
			exec [RDF.].GetDataRDF @NodeListXML = @NodeListXML, @expand = 1, @showDetails = 0, @returnXML = 0, @dataStr = @ObjectNodesRDF OUTPUT
		*/
		create table #OutputNodes (
			NodeID bigint primary key,
			k int
		)
		insert into #OutputNodes (NodeID,k)
			SELECT DISTINCT  NodeID,0
			from #Node
			where SortOrder >= IsNull(@offset,0) and SortOrder < IsNull(IsNull(@offset,0)+@limit,SortOrder+1)
		declare @k int
		select @k = 0
		while @k < 10
		begin
			insert into #OutputNodes (NodeID,k)
				select distinct e.ExpandNodeID, @k+1
				from #OutputNodes o, [Search.Cache].[Public.NodeExpand] e
				where o.k = @k and o.NodeID = e.NodeID
					and e.ExpandNodeID not in (select NodeID from #OutputNodes)
			if @@ROWCOUNT = 0
				select @k = 10
			else
				select @k = @k + 1
		end
		select @ObjectNodesRDF = replace(replace(cast((
				select r.RDF + ''
				from #OutputNodes n, [Search.Cache].[Public.NodeRDF] r
				where n.NodeID = r.NodeID
				order by n.NodeID
				for xml path(''), type
			) as nvarchar(max)),'_TAGLT_','<'),'_TAGGT_','>')
	end


	-------------------------------------------------------
	-- Form search results RDF
	-------------------------------------------------------

	declare @results nvarchar(max)

	select @results = ''
			+'<rdf:Description rdf:nodeID="SearchResults">'
			+'<rdf:type rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#Network" />'
			+'<rdfs:label>Search Results</rdfs:label>'
			+'<prns:numberOfConnections rdf:datatype="http://www.w3.org/2001/XMLSchema#int">'+cast(IsNull(@NumberOfConnections,0) as nvarchar(50))+'</prns:numberOfConnections>'
			+'<prns:offset rdf:datatype="http://www.w3.org/2001/XMLSchema#int"' + IsNull('>'+cast(@offset as nvarchar(50))+'</prns:offset>',' />')
			+'<prns:limit rdf:datatype="http://www.w3.org/2001/XMLSchema#int"' + IsNull('>'+cast(@limit as nvarchar(50))+'</prns:limit>',' />')
			+'<prns:maxWeight rdf:datatype="http://www.w3.org/2001/XMLSchema#float"' + IsNull('>'+cast(@MaxWeight as nvarchar(50))+'</prns:maxWeight>',' />')
			+'<prns:minWeight rdf:datatype="http://www.w3.org/2001/XMLSchema#float"' + IsNull('>'+cast(@MinWeight as nvarchar(50))+'</prns:minWeight>',' />')
			+'<vivo:overview rdf:parseType="Literal">'
			+IsNull(cast(@SearchOptions as nvarchar(max)),'')
			+'<SearchDetails>'+IsNull(cast(@SearchPhraseXML as nvarchar(max)),'')+'</SearchDetails>'
			+IsNull('<prns:matchesClassGroupsList>'+@MatchesClassGroups+'</prns:matchesClassGroupsList>','')
			+'</vivo:overview>'
			+IsNull((select replace(replace(cast((
					select '_TAGLT_prns:hasConnection rdf:nodeID="C'+cast(SortOrder as nvarchar(50))+'" /_TAGGT_'
					from #Node
					where SortOrder >= IsNull(@offset,0) and SortOrder < IsNull(IsNull(@offset,0)+@limit,SortOrder+1)
					order by SortOrder
					for xml path(''), type
				) as nvarchar(max)),'_TAGLT_','<'),'_TAGGT_','>')),'')
			+'</rdf:Description>'
			+IsNull((select replace(replace(cast((
					select ''
						+'_TAGLT_rdf:Description rdf:nodeID="C'+cast(x.SortOrder as nvarchar(50))+'"_TAGGT_'
						+'_TAGLT_prns:connectionWeight_TAGGT_'+cast(x.Weight as nvarchar(50))+'_TAGLT_/prns:connectionWeight_TAGGT_'
						+'_TAGLT_prns:sortOrder_TAGGT_'+cast(x.SortOrder as nvarchar(50))+'_TAGLT_/prns:sortOrder_TAGGT_'
						+'_TAGLT_rdf:object rdf:resource="'+replace(n.Value,'"','')+'"/_TAGGT_'
						+'_TAGLT_rdf:type rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#Connection" /_TAGGT_'
						+'_TAGLT_rdfs:label_TAGGT_'+(case when s.ShortLabel<>'' then ltrim(rtrim(s.ShortLabel)) else 'Untitled' end)+'_TAGLT_/rdfs:label_TAGGT_'
						+IsNull(+'_TAGLT_vivo:overview_TAGGT_'+s.ClassName+'_TAGLT_/vivo:overview_TAGGT_','')
						+'_TAGLT_/rdf:Description_TAGGT_'
					from #Node x, [RDF.].Node n, [Search.Cache].[Public.NodeSummary] s
					where x.SortOrder >= IsNull(@offset,0) and x.SortOrder < IsNull(IsNull(@offset,0)+@limit,x.SortOrder+1)
						and x.NodeID = n.NodeID
						and x.NodeID = s.NodeID
					order by x.SortOrder
					for xml path(''), type
				) as nvarchar(max)),'_TAGLT_','<'),'_TAGGT_','>')),'')
			+IsNull(@ObjectNodesRDF,'')

	declare @x as varchar(max)
	select @x = '<rdf:RDF'
	select @x = @x + ' xmlns:'+Prefix+'="'+URI+'"' 
		from [Ontology.].Namespace
	select @x = @x + ' >' + @results + '</rdf:RDF>'
	select cast(@x as xml) RDF


	-------------------------------------------------------
	-- Log results
	-------------------------------------------------------

	update [Search.].[History.Query]
		set EndDate = GetDate(),
			DurationMS = datediff(ms,StartDate,GetDate()),
			NumberOfConnections = IsNull(@NumberOfConnections,0)
		where SearchHistoryQueryID = @SearchHistoryQueryID
	
	insert into [Search.].[History.Phrase] (SearchHistoryQueryID, PhraseID, ThesaurusMatch, Phrase, EndDate, IsBot, NumberOfConnections)
		select	@SearchHistoryQueryID,
				PhraseID,
				ThesaurusMatch,
				Phrase,
				GetDate(),
				@IsBot,
				IsNull(@NumberOfConnections,0)
			from @PhraseList

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Search.Cache].[Private.GetNodes]'
GO
ALTER PROCEDURE [Search.Cache].[Private.GetNodes]
	@SearchOptions XML,
	@SessionID UNIQUEIDENTIFIER=NULL
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
		-- interfering with SELECT statements.
		SET NOCOUNT ON;

	/*
	
	EXEC [Search.Cache].[Private.GetNodes] @SearchOptions = '
	<SearchOptions>
		<MatchOptions>
			<SearchString ExactMatch="false">options for "lung cancer" treatment</SearchString>
			<ClassURI>http://xmlns.com/foaf/0.1/Person</ClassURI>
			<SearchFiltersList>
				<SearchFilter Property="http://xmlns.com/foaf/0.1/lastName" MatchType="Left">Smit</SearchFilter>
			</SearchFiltersList>
		</MatchOptions>
		<OutputOptions>
			<Offset>0</Offset>
			<Limit>5</Limit>
			<SortByList>
				<SortBy IsDesc="1" Property="http://xmlns.com/foaf/0.1/firstName" />
				<SortBy IsDesc="0" Property="http://xmlns.com/foaf/0.1/lastName" />
			</SortByList>
		</OutputOptions>	
	</SearchOptions>
	'
		
	*/

	declare @MatchOptions xml
	declare @OutputOptions xml
	declare @SearchString varchar(500)
	declare @ClassGroupURI varchar(400)
	declare @ClassURI varchar(400)
	declare @SearchFiltersXML xml
	declare @offset bigint
	declare @limit bigint
	declare @SortByXML xml
	declare @DoExpandedSearch bit
	
	select	@MatchOptions = @SearchOptions.query('SearchOptions[1]/MatchOptions[1]'),
			@OutputOptions = @SearchOptions.query('SearchOptions[1]/OutputOptions[1]')
	
	select	@SearchString = @MatchOptions.value('MatchOptions[1]/SearchString[1]','varchar(500)'),
			@DoExpandedSearch = (case when @MatchOptions.value('MatchOptions[1]/SearchString[1]/@ExactMatch','varchar(50)') = 'true' then 0 else 1 end),
			@ClassGroupURI = @MatchOptions.value('MatchOptions[1]/ClassGroupURI[1]','varchar(400)'),
			@ClassURI = @MatchOptions.value('MatchOptions[1]/ClassURI[1]','varchar(400)'),
			@SearchFiltersXML = @MatchOptions.query('MatchOptions[1]/SearchFiltersList[1]'),
			@offset = @OutputOptions.value('OutputOptions[1]/Offset[1]','bigint'),
			@limit = @OutputOptions.value('OutputOptions[1]/Limit[1]','bigint'),
			@SortByXML = @OutputOptions.query('OutputOptions[1]/SortByList[1]')

	declare @baseURI nvarchar(400)
	select @baseURI = value from [Framework.].Parameter where ParameterID = 'baseURI'

	declare @d datetime
	select @d = GetDate()
	

	-------------------------------------------------------
	-- Parse search string and convert to fulltext query
	-------------------------------------------------------

	declare @NumberOfPhrases INT
	declare @CombinedSearchString VARCHAR(8000)
	declare @SearchPhraseXML XML
	declare @SearchPhraseFormsXML XML
	declare @ParseProcessTime INT

	EXEC [Search.].[ParseSearchString]	@SearchString = @SearchString,
										@NumberOfPhrases = @NumberOfPhrases OUTPUT,
										@CombinedSearchString = @CombinedSearchString OUTPUT,
										@SearchPhraseXML = @SearchPhraseXML OUTPUT,
										@SearchPhraseFormsXML = @SearchPhraseFormsXML OUTPUT,
										@ProcessTime = @ParseProcessTime OUTPUT

	declare @PhraseList table (PhraseID int, Phrase varchar(max), ThesaurusMatch bit, Forms varchar(max))
	insert into @PhraseList (PhraseID, Phrase, ThesaurusMatch, Forms)
	select	x.value('@ID','INT'),
			x.value('.','VARCHAR(MAX)'),
			x.value('@ThesaurusMatch','BIT'),
			x.value('@Forms','VARCHAR(MAX)')
		from @SearchPhraseFormsXML.nodes('//SearchPhrase') as p(x)

	--SELECT @NumberOfPhrases, @CombinedSearchString, @SearchPhraseXML, @SearchPhraseFormsXML, @ParseProcessTime
	--SELECT * FROM @PhraseList
	--select datediff(ms,@d,GetDate())


	-------------------------------------------------------
	-- Parse search filters
	-------------------------------------------------------

	create table #SearchFilters (
		SearchFilterID int identity(0,1) primary key,
		IsExclude bit,
		PropertyURI varchar(400),
		PropertyURI2 varchar(400),
		MatchType varchar(100),
		Value nvarchar(max),
		Predicate bigint,
		Predicate2 bigint
	)
	
	insert into #SearchFilters (IsExclude, PropertyURI, PropertyURI2, MatchType, Value, Predicate, Predicate2)	
		select t.IsExclude, t.PropertyURI, t.PropertyURI2, t.MatchType, t.Value,
				--left(t.Value,750)+(case when t.MatchType='Left' then '%' else '' end),
				t.Predicate, t.Predicate2
			from (
				select IsNull(IsExclude,0) IsExclude, PropertyURI, PropertyURI2, MatchType, Value,
					[RDF.].fnURI2NodeID(PropertyURI) Predicate,
					[RDF.].fnURI2NodeID(PropertyURI2) Predicate2
				from (
					select distinct S.x.value('@IsExclude','bit') IsExclude,
							S.x.value('@Property','varchar(400)') PropertyURI,
							S.x.value('@Property2','varchar(400)') PropertyURI2,
							S.x.value('@MatchType','varchar(100)') MatchType,
							--S.x.value('.','nvarchar(max)') Value
							--cast(S.x.query('./*') as nvarchar(max)) Value
							(case when cast(S.x.query('./*') as nvarchar(max)) <> '' then cast(S.x.query('./*') as nvarchar(max)) else S.x.value('.','nvarchar(max)') end) Value
					from @SearchFiltersXML.nodes('//SearchFilter') as S(x)
				) t
			) t
			where t.Value IS NOT NULL and t.Value <> ''
			
	declare @NumberOfIncludeFilters int
	select @NumberOfIncludeFilters = IsNull((select count(*) from #SearchFilters where IsExclude=0),0)

	-------------------------------------------------------
	-- SPECIAL CASE FOR CATALYST: Harvard ID
	-------------------------------------------------------
/**
	declare @HarvardID varchar(10)
	declare @HarvardIDFilter int
	select @HarvardID = cast(Value as varchar(10)),
			@HarvardIDFilter = SearchFilterID
		from #SearchFilters
		where PropertyURI = 'http://profiles.catalyst.harvard.edu/ontology/catalyst#harvardID' and PropertyURI2 is null
	if (@HarvardID is not null) and (@HarvardID <> '') and (IsNumeric(@HarvardID)=1)
	begin
		-- Make sure the HarvardID is in the MPI table and get the PersonID
		declare @PersonID int
		if not exists (select * from resnav_home.dbo.mpi where HarvardID = @HarvardID and EndDate is null)
		begin
			insert into resnav_home.dbo.mpi (ProfilesUserid, HarvardID, eCommonsLogin, eCommonsUsername, IsActive, StartDate)
				select (select max(ProfilesUserID)+1 from resnav_home.dbo.mpi),
					@HarvardID, '', '', 1, GetDate()
		end
		declare @eCommonsLogin varchar(50)
		select @PersonID = ProfilesUserID, @eCommonsLogin = eCommonsLogin
			from resnav_home.dbo.mpi
			where HarvardID = @HarvardID and EndDate is null
		-- Determine if the PersonID has a node
		declare @PersonNodeID bigint
		select @PersonNodeID = NodeID
			from [RDF.Stage].InternalNodeMap
			where InternalHash = [RDF.].fnValueHash(null,null,'http://xmlns.com/foaf/0.1/Person^^Person^^'+cast(@PersonID as varchar(50)))
		if @PersonNodeID is not null
		begin
			-- Replace HarvardID filter with a PersonID filter
			update #SearchFilters
				set PropertyURI = 'http://profiles.catalyst.harvard.edu/ontology/prns#personId',
					Value = cast(@PersonID as varchar(50)),
					Predicate = [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#personId')
				where PropertyURI = 'http://profiles.catalyst.harvard.edu/ontology/catalyst#harvardID'
		end
		else
		begin
			-- Return a hard-coded result
			declare @HUresults nvarchar(max)
			select @HUresults = 
				  '<rdf:Description rdf:nodeID="SearchResults">
					<rdf:type rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#Network" />
					<rdfs:label>Search Results</rdfs:label>
					<prns:numberOfConnections rdf:datatype="http://www.w3.org/2001/XMLSchema#int">1</prns:numberOfConnections>
					<prns:offset rdf:datatype="http://www.w3.org/2001/XMLSchema#int"' + IsNull('>'+cast(@offset as nvarchar(50))+'</prns:offset>',' />') +'
					<prns:limit rdf:datatype="http://www.w3.org/2001/XMLSchema#int"' + IsNull('>'+cast(@limit as nvarchar(50))+'</prns:limit>',' />') +'
					<prns:maxWeight rdf:datatype="http://www.w3.org/2001/XMLSchema#float">1</prns:maxWeight>
					<prns:minWeight rdf:datatype="http://www.w3.org/2001/XMLSchema#float">1</prns:minWeight>
					<vivo:overview rdf:parseType="Literal">
					  '+IsNull(cast(@SearchOptions as nvarchar(max)),'')+'
					  <prns:matchesClassGroupsList>
						<prns:matchesClassGroup rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#ClassGroupPeople">
						  <rdfs:label>People</rdfs:label>
						  <prns:numberOfConnections rdf:datatype="http://www.w3.org/2001/XMLSchema#int">1</prns:numberOfConnections>
						  <prns:sortOrder>1</prns:sortOrder>
						  <prns:matchesClass rdf:resource="http://xmlns.com/foaf/0.1/Person">
							<rdfs:label>Person</rdfs:label>
							<prns:numberOfConnections rdf:datatype="http://www.w3.org/2001/XMLSchema#int">1</prns:numberOfConnections>
							<prns:sortOrder>1</prns:sortOrder>
						  </prns:matchesClass>
						</prns:matchesClassGroup>
					  </prns:matchesClassGroupsList>
					</vivo:overview>
					<prns:hasConnection rdf:nodeID="C0" />
				  </rdf:Description>
				  <rdf:Description rdf:nodeID="C0">
					<prns:connectionWeight>1</prns:connectionWeight>
					<prns:sortOrder>0</prns:sortOrder>
					<rdf:object rdf:nodeID="P0" />
					<rdf:type rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#Connection" />
					<vivo:overview>Person</vivo:overview>
				  </rdf:Description>
				  <rdf:Description rdf:nodeID="P0">
					<catalyst:eCommonsLogin>' + IsNull(@eCommonsLogin,'') + '</catalyst:eCommonsLogin>
					<prns:personId>' + cast(@PersonID as varchar(50)) + '</prns:personId>
					<rdf:type rdf:resource="http://xmlns.com/foaf/0.1/Agent" />
					<rdf:type rdf:resource="http://xmlns.com/foaf/0.1/Person" />
				  </rdf:Description>'
			declare @HUx as varchar(max)
			select @HUx = '<rdf:RDF'
			select @HUx = @HUx + ' xmlns:'+Prefix+'="'+URI+'"' 
				from [Ontology.].Namespace
			select @HUx = @HUx + ' >' + @HUresults + '</rdf:RDF>'
			select cast(@HUx as xml) RDF
			return
		end
	end

**/
	-------------------------------------------------------
	-- Parse sort by options
	-------------------------------------------------------

	create table #SortBy (
		SortByID int identity(1,1) primary key,
		IsDesc bit,
		PropertyURI varchar(400),
		PropertyURI2 varchar(400),
		PropertyURI3 varchar(400),
		Predicate bigint,
		Predicate2 bigint,
		Predicate3 bigint
	)
	
	insert into #SortBy (IsDesc, PropertyURI, PropertyURI2, PropertyURI3, Predicate, Predicate2, Predicate3)	
		select IsNull(IsDesc,0), PropertyURI, PropertyURI2, PropertyURI3,
				[RDF.].fnURI2NodeID(PropertyURI) Predicate,
				[RDF.].fnURI2NodeID(PropertyURI2) Predicate2,
				[RDF.].fnURI2NodeID(PropertyURI3) Predicate3
			from (
				select S.x.value('@IsDesc','bit') IsDesc,
						S.x.value('@Property','varchar(400)') PropertyURI,
						S.x.value('@Property2','varchar(400)') PropertyURI2,
						S.x.value('@Property3','varchar(400)') PropertyURI3
				from @SortByXML.nodes('//SortBy') as S(x)
			) t

	-------------------------------------------------------
	-- Get initial list of matching nodes (before filters)
	-------------------------------------------------------

	create table #FullNodeMatch (
		NodeID bigint not null,
		Paths bigint,
		Weight float
	)

	if @CombinedSearchString <> ''
	begin
	--select @CombinedSearchString, @NumberOfPhrases, @DoExpandedSearch
		-- Get nodes that match separate phrases
		create table #PhraseNodeMatch (
			PhraseID int not null,
			NodeID bigint not null,
			Paths bigint,
			Weight float
		)
		if (@NumberOfPhrases > 1) and (@DoExpandedSearch = 1)
		begin
			declare @PhraseSearchString varchar(8000)
			declare @loop int
			select @loop = 1
			while @loop <= @NumberOfPhrases
			begin
				select @PhraseSearchString = Forms
					from @PhraseList
					where PhraseID = @loop
				insert into #PhraseNodeMatch (PhraseID, NodeID, Paths, Weight)
					select @loop, s.NodeID, count(*) Paths, 1-exp(sum(log(case when s.Weight*m.Weight > 0.999999 then 0.000001 else 1-s.Weight*m.Weight end))) Weight
						from [Search.Cache].[Private.NodeMap] s, (
							select [Key] NodeID, [Rank]*0.001 Weight
								from Containstable ([RDF.].Node, value, @PhraseSearchString) n
						) m
						where s.MatchedByNodeID = m.NodeID
						group by s.NodeID
				select @loop = @loop + 1
			end
			--create clustered index idx_n on #PhraseNodeMatch(NodeID)
		end

		create table #TempMatchNodes (
			NodeID bigint,
			MatchedByNodeID bigint,
			Distance int,
			Paths int,
			Weight float,
			mWeight float
		)
		insert into #TempMatchNodes (NodeID, MatchedByNodeID, Distance, Paths, Weight, mWeight)
			select s.*, m.Weight mWeight
				from [Search.Cache].[Private.NodeMap] s, (
					select [Key] NodeID, [Rank]*0.001 Weight
						from Containstable ([RDF.].Node, value, @CombinedSearchString) n
				) m
				where s.MatchedByNodeID = m.NodeID

		insert into #FullNodeMatch (NodeID, Paths, Weight)
			select IsNull(a.NodeID,b.NodeID) NodeID, IsNull(a.Paths,b.Paths) Paths,
					(case when a.weight is null or b.weight is null then IsNull(a.Weight,b.Weight) else 1-(1-a.Weight)*(1-b.Weight) end) Weight
				from (
					select NodeID, exp(sum(log(Paths))) Paths, exp(sum(log(Weight))) Weight
						from #PhraseNodeMatch
						group by NodeID
						having count(*) = @NumberOfPhrases
				) a full outer join (
					select NodeID, count(*) Paths, 1-exp(sum(log(case when Weight*mWeight > 0.999999 then 0.000001 else 1-Weight*mWeight end))) Weight
						from #TempMatchNodes
						group by NodeID
				) b on a.NodeID = b.NodeID
		--select 'Text Matches Found', datediff(ms,@d,getdate())
	end
	else if (@NumberOfIncludeFilters > 0)
	begin
		insert into #FullNodeMatch (NodeID, Paths, Weight)
			select t1.Subject, 1, 1
				from #SearchFilters f
					inner join [RDF.].Triple t1
						on f.Predicate is not null
							and t1.Predicate = f.Predicate 
							and t1.ViewSecurityGroup between -30 and -1
					left outer join [Search.Cache].[Private.NodePrefix] n1
						on n1.NodeID = t1.Object
					left outer join [RDF.].Triple t2
						on f.Predicate2 is not null
							and t2.Subject = n1.NodeID
							and t2.Predicate = f.Predicate2
							and t2.ViewSecurityGroup between -30 and -1
					left outer join [Search.Cache].[Private.NodePrefix] n2
						on n2.NodeID = t2.Object
				where f.IsExclude = 0
					and 1 = (case	when (f.Predicate2 is not null) then
										(case	when f.MatchType = 'Left' then
													(case when n2.Prefix like f.Value+'%' then 1 else 0 end)
												when f.MatchType = 'In' then
													(case when n2.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
												else
													(case when n2.Prefix = f.Value then 1 else 0 end)
												end)
									else
										(case	when f.MatchType = 'Left' then
													(case when n1.Prefix like f.Value+'%' then 1 else 0 end)
												when f.MatchType = 'In' then
													(case when n1.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
												else
													(case when n1.Prefix = f.Value then 1 else 0 end)
												end)
									end)
					--and (case when f.Predicate2 is not null then n2.Prefix else n1.Prefix end)
					--	like f.Value
				group by t1.Subject
				having count(distinct f.SearchFilterID) = @NumberOfIncludeFilters
		delete from #SearchFilters where IsExclude = 0
		select @NumberOfIncludeFilters = 0
	end
	else if (IsNull(@ClassGroupURI,'') <> '' or IsNull(@ClassURI,'') <> '')
	begin
		insert into #FullNodeMatch (NodeID, Paths, Weight)
			select distinct n.NodeID, 1, 1
				from [Search.Cache].[Private.NodeClass] n, [Ontology.].ClassGroupClass c
				where n.Class = c._ClassNode
					and ((@ClassGroupURI is null) or (c.ClassGroupURI = @ClassGroupURI))
					and ((@ClassURI is null) or (c.ClassURI = @ClassURI))
		select @ClassGroupURI = null, @ClassURI = null
	end

	-------------------------------------------------------
	-- Run the actual search
	-------------------------------------------------------
	create table #Node (
		SortOrder bigint identity(0,1) primary key,
		NodeID bigint,
		Paths bigint,
		Weight float
	)

	insert into #Node (NodeID, Paths, Weight)
		select s.NodeID, s.Paths, s.Weight
			from #FullNodeMatch s
				inner join [Search.Cache].[Private.NodeSummary] n on
					s.NodeID = n.NodeID
					and ( IsNull(@ClassGroupURI,@ClassURI) is null or s.NodeID in (
							select NodeID
								from [Search.Cache].[Private.NodeClass] x, [Ontology.].ClassGroupClass c
								where x.Class = c._ClassNode
									and c.ClassGroupURI = IsNull(@ClassGroupURI,c.ClassGroupURI)
									and c.ClassURI = IsNull(@ClassURI,c.ClassURI)
						) )
					and ( @NumberOfIncludeFilters =
							(select count(distinct f.SearchFilterID)
								from #SearchFilters f
									inner join [RDF.].Triple t1
										on f.Predicate is not null
											and t1.Subject = s.NodeID
											and t1.Predicate = f.Predicate 
											and t1.ViewSecurityGroup between -30 and -1
									left outer join [Search.Cache].[Private.NodePrefix] n1
										on n1.NodeID = t1.Object
									left outer join [RDF.].Triple t2
										on f.Predicate2 is not null
											and t2.Subject = n1.NodeID
											and t2.Predicate = f.Predicate2
											and t2.ViewSecurityGroup between -30 and -1
									left outer join [Search.Cache].[Private.NodePrefix] n2
										on n2.NodeID = t2.Object
								where f.IsExclude = 0
									and 1 = (case	when (f.Predicate2 is not null) then
														(case	when f.MatchType = 'Left' then
																	(case when n2.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n2.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n2.Prefix = f.Value then 1 else 0 end)
																end)
													else
														(case	when f.MatchType = 'Left' then
																	(case when n1.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n1.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n1.Prefix = f.Value then 1 else 0 end)
																end)
													end)
									--and (case when f.Predicate2 is not null then n2.Prefix else n1.Prefix end)
									--	like f.Value
							)
						)
					and not exists (
							select *
								from #SearchFilters f
									inner join [RDF.].Triple t1
										on f.Predicate is not null
											and t1.Subject = s.NodeID
											and t1.Predicate = f.Predicate 
											and t1.ViewSecurityGroup between -30 and -1
									left outer join [Search.Cache].[Private.NodePrefix] n1
										on n1.NodeID = t1.Object
									left outer join [RDF.].Triple t2
										on f.Predicate2 is not null
											and t2.Subject = n1.NodeID
											and t2.Predicate = f.Predicate2
											and t2.ViewSecurityGroup between -30 and -1
									left outer join [Search.Cache].[Private.NodePrefix] n2
										on n2.NodeID = t2.Object
								where f.IsExclude = 1
									and 1 = (case	when (f.Predicate2 is not null) then
														(case	when f.MatchType = 'Left' then
																	(case when n2.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n2.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n2.Prefix = f.Value then 1 else 0 end)
																end)
													else
														(case	when f.MatchType = 'Left' then
																	(case when n1.Prefix like f.Value+'%' then 1 else 0 end)
																when f.MatchType = 'In' then
																	(case when n1.Prefix in (select r.x.value('.','varchar(max)') v from (select cast(f.Value as xml) x) t cross apply x.nodes('//Item') as r(x)) then 1 else 0 end)
																else
																	(case when n1.Prefix = f.Value then 1 else 0 end)
																end)
													end)
									--and (case when f.Predicate2 is not null then n2.Prefix else n1.Prefix end)
									--	like f.Value
						)
				outer apply (
					select	max(case when SortByID=1 then AscSortBy else null end) AscSortBy1,
							max(case when SortByID=2 then AscSortBy else null end) AscSortBy2,
							max(case when SortByID=3 then AscSortBy else null end) AscSortBy3,
							max(case when SortByID=1 then DescSortBy else null end) DescSortBy1,
							max(case when SortByID=2 then DescSortBy else null end) DescSortBy2,
							max(case when SortByID=3 then DescSortBy else null end) DescSortBy3
						from (
							select	SortByID,
									(case when f.IsDesc = 1 then null
											when f.Predicate3 is not null then n3.Value
											when f.Predicate2 is not null then n2.Value
											else n1.Value end) AscSortBy,
									(case when f.IsDesc = 0 then null
											when f.Predicate3 is not null then n3.Value
											when f.Predicate2 is not null then n2.Value
											else n1.Value end) DescSortBy
								from #SortBy f
									inner join [RDF.].Triple t1
										on f.Predicate is not null
											and t1.Subject = s.NodeID
											and t1.Predicate = f.Predicate 
											and t1.ViewSecurityGroup between -30 and -1
									left outer join [RDF.].Node n1
										on n1.NodeID = t1.Object
											and n1.ViewSecurityGroup between -30 and -1
									left outer join [RDF.].Triple t2
										on f.Predicate2 is not null
											and t2.Subject = n1.NodeID
											and t2.Predicate = f.Predicate2
											and t2.ViewSecurityGroup between -30 and -1
									left outer join [RDF.].Node n2
										on n2.NodeID = t2.Object
											and n2.ViewSecurityGroup between -30 and -1
									left outer join [RDF.].Triple t3
										on f.Predicate3 is not null
											and t3.Subject = n2.NodeID
											and t3.Predicate = f.Predicate3
											and t3.ViewSecurityGroup between -30 and -1
									left outer join [RDF.].Node n3
										on n3.NodeID = t3.Object
											and n3.ViewSecurityGroup between -30 and -1
							) t
					) o
			order by	(case when o.AscSortBy1 is null then 1 else 0 end),
						o.AscSortBy1,
						(case when o.DescSortBy1 is null then 1 else 0 end),
						o.DescSortBy1 desc,
						(case when o.AscSortBy2 is null then 1 else 0 end),
						o.AscSortBy2,
						(case when o.DescSortBy2 is null then 1 else 0 end),
						o.DescSortBy2 desc,
						(case when o.AscSortBy3 is null then 1 else 0 end),
						o.AscSortBy3,
						(case when o.DescSortBy3 is null then 1 else 0 end),
						o.DescSortBy3 desc,
						s.Weight desc,
						n.ShortLabel,
						n.NodeID


	--select 'Search Nodes Found', datediff(ms,@d,GetDate())

	-------------------------------------------------------
	-- Get network counts
	-------------------------------------------------------

	declare @NumberOfConnections as bigint
	declare @MaxWeight as float
	declare @MinWeight as float

	select @NumberOfConnections = count(*), @MaxWeight = max(Weight), @MinWeight = min(Weight) 
		from #Node

	-------------------------------------------------------
	-- Get matching class groups and classes
	-------------------------------------------------------

	declare @MatchesClassGroups nvarchar(max)

	select c.ClassGroupURI, c.ClassURI, n.NodeID
		into #NodeClass
		from #Node n, [Search.Cache].[Private.NodeClass] s, [Ontology.].ClassGroupClass c
		where n.NodeID = s.NodeID and s.Class = c._ClassNode

	;with a as (
		select ClassGroupURI, count(distinct NodeID) NumberOfNodes
			from #NodeClass s
			group by ClassGroupURI
	), b as (
		select ClassGroupURI, ClassURI, count(distinct NodeID) NumberOfNodes
			from #NodeClass s
			group by ClassGroupURI, ClassURI
	)
	select @MatchesClassGroups = replace(cast((
			select	g.ClassGroupURI "@rdf_.._resource", 
				g._ClassGroupLabel "rdfs_.._label",
				'http://www.w3.org/2001/XMLSchema#int' "prns_.._numberOfConnections/@rdf_.._datatype",
				a.NumberOfNodes "prns_.._numberOfConnections",
				g.SortOrder "prns_.._sortOrder",
				(
					select	c.ClassURI "@rdf_.._resource",
							c._ClassLabel "rdfs_.._label",
							'http://www.w3.org/2001/XMLSchema#int' "prns_.._numberOfConnections/@rdf_.._datatype",
							b.NumberOfNodes "prns_.._numberOfConnections",
							c.SortOrder "prns_.._sortOrder"
						from b, [Ontology.].ClassGroupClass c
						where b.ClassGroupURI = c.ClassGroupURI and b.ClassURI = c.ClassURI
							and c.ClassGroupURI = g.ClassGroupURI
						order by c.SortOrder
						for xml path('prns_.._matchesClass'), type
				)
			from a, [Ontology.].ClassGroup g
			where a.ClassGroupURI = g.ClassGroupURI and g.IsVisible = 1
			order by g.SortOrder
			for xml path('prns_.._matchesClassGroup'), type
		) as nvarchar(max)),'_.._',':')

	-------------------------------------------------------
	-- Get RDF of search results objects
	-------------------------------------------------------

	declare @ObjectNodesRDF nvarchar(max)

	if @NumberOfConnections > 0
	begin
		/*
			-- Alternative methods that uses GetDataRDF to get the RDF
			declare @NodeListXML xml
			select @NodeListXML = (
					select (
							select NodeID "@ID"
							from #Node
							where SortOrder >= IsNull(@offset,0) and SortOrder < IsNull(IsNull(@offset,0)+@limit,SortOrder+1)
							order by SortOrder
							for xml path('Node'), type
							)
					for xml path('NodeList'), type
				)
			exec [RDF.].GetDataRDF @NodeListXML = @NodeListXML, @expand = 1, @showDetails = 0, @returnXML = 0, @dataStr = @ObjectNodesRDF OUTPUT
		*/
		create table #OutputNodes (
			NodeID bigint primary key,
			k int
		)
		insert into #OutputNodes (NodeID,k)
			select DISTINCT NodeID,0
			from #Node
			where SortOrder >= IsNull(@offset,0) and SortOrder < IsNull(IsNull(@offset,0)+@limit,SortOrder+1)
		declare @k int
		select @k = 0
		while @k < 10
		begin
			insert into #OutputNodes (NodeID,k)
				select distinct e.ExpandNodeID, @k+1
				from #OutputNodes o, [Search.Cache].[Private.NodeExpand] e
				where o.k = @k and o.NodeID = e.NodeID
					and e.ExpandNodeID not in (select NodeID from #OutputNodes)
			if @@ROWCOUNT = 0
				select @k = 10
			else
				select @k = @k + 1
		end
		select @ObjectNodesRDF = replace(replace(cast((
				select r.RDF + ''
				from #OutputNodes n, [Search.Cache].[Private.NodeRDF] r
				where n.NodeID = r.NodeID
				order by n.NodeID
				for xml path(''), type
			) as nvarchar(max)),'_TAGLT_','<'),'_TAGGT_','>')
	end


	-------------------------------------------------------
	-- Form search results RDF
	-------------------------------------------------------

	declare @results nvarchar(max)

	select @results = ''
			+'<rdf:Description rdf:nodeID="SearchResults">'
			+'<rdf:type rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#Network" />'
			+'<rdfs:label>Search Results</rdfs:label>'
			+'<prns:numberOfConnections rdf:datatype="http://www.w3.org/2001/XMLSchema#int">'+cast(IsNull(@NumberOfConnections,0) as nvarchar(50))+'</prns:numberOfConnections>'
			+'<prns:offset rdf:datatype="http://www.w3.org/2001/XMLSchema#int"' + IsNull('>'+cast(@offset as nvarchar(50))+'</prns:offset>',' />')
			+'<prns:limit rdf:datatype="http://www.w3.org/2001/XMLSchema#int"' + IsNull('>'+cast(@limit as nvarchar(50))+'</prns:limit>',' />')
			+'<prns:maxWeight rdf:datatype="http://www.w3.org/2001/XMLSchema#float"' + IsNull('>'+cast(@MaxWeight as nvarchar(50))+'</prns:maxWeight>',' />')
			+'<prns:minWeight rdf:datatype="http://www.w3.org/2001/XMLSchema#float"' + IsNull('>'+cast(@MinWeight as nvarchar(50))+'</prns:minWeight>',' />')
			+'<vivo:overview rdf:parseType="Literal">'
			+IsNull(cast(@SearchOptions as nvarchar(max)),'')
			+'<SearchDetails>'+IsNull(cast(@SearchPhraseXML as nvarchar(max)),'')+'</SearchDetails>'
			+IsNull('<prns:matchesClassGroupsList>'+@MatchesClassGroups+'</prns:matchesClassGroupsList>','')
			+'</vivo:overview>'
			+IsNull((select replace(replace(cast((
					select '_TAGLT_prns:hasConnection rdf:nodeID="C'+cast(SortOrder as nvarchar(50))+'" /_TAGGT_'
					from #Node
					where SortOrder >= IsNull(@offset,0) and SortOrder < IsNull(IsNull(@offset,0)+@limit,SortOrder+1)
					order by SortOrder
					for xml path(''), type
				) as nvarchar(max)),'_TAGLT_','<'),'_TAGGT_','>')),'')
			+'</rdf:Description>'
			+IsNull((select replace(replace(cast((
					select ''
						+'_TAGLT_rdf:Description rdf:nodeID="C'+cast(x.SortOrder as nvarchar(50))+'"_TAGGT_'
						+'_TAGLT_prns:connectionWeight_TAGGT_'+cast(x.Weight as nvarchar(50))+'_TAGLT_/prns:connectionWeight_TAGGT_'
						+'_TAGLT_prns:sortOrder_TAGGT_'+cast(x.SortOrder as nvarchar(50))+'_TAGLT_/prns:sortOrder_TAGGT_'
						+'_TAGLT_rdf:object rdf:resource="'+replace(n.Value,'"','')+'"/_TAGGT_'
						+'_TAGLT_rdf:type rdf:resource="http://profiles.catalyst.harvard.edu/ontology/prns#Connection" /_TAGGT_'
						+'_TAGLT_rdfs:label_TAGGT_'+(case when s.ShortLabel<>'' then ltrim(rtrim(s.ShortLabel)) else 'Untitled' end)+'_TAGLT_/rdfs:label_TAGGT_'
						+IsNull(+'_TAGLT_vivo:overview_TAGGT_'+s.ClassName+'_TAGLT_/vivo:overview_TAGGT_','')
						+'_TAGLT_/rdf:Description_TAGGT_'
					from #Node x, [RDF.].Node n, [Search.Cache].[Private.NodeSummary] s
					where x.SortOrder >= IsNull(@offset,0) and x.SortOrder < IsNull(IsNull(@offset,0)+@limit,x.SortOrder+1)
						and x.NodeID = n.NodeID
						and x.NodeID = s.NodeID
					order by x.SortOrder
					for xml path(''), type
				) as nvarchar(max)),'_TAGLT_','<'),'_TAGGT_','>')),'')
			+IsNull(@ObjectNodesRDF,'')

	declare @x as varchar(max)
	select @x = '<rdf:RDF'
	select @x = @x + ' xmlns:'+Prefix+'="'+URI+'"' 
		from [Ontology.].Namespace
	select @x = @x + ' >' + @results + '</rdf:RDF>'
	select cast(@x as xml) RDF


END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Framework.].[CreateInstallData]'
GO
ALTER procedure [Framework.].[CreateInstallData]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	declare @x xml

	select @x = (
		select
			(
				select
					--------------------------------------------------------
					-- [Framework.]
					--------------------------------------------------------
					(
						select	'[Framework.].[Parameter]' 'Table/@Name',
								(
									select	ParameterID 'ParameterID', 
											Value 'Value'
									from [Framework.].[Parameter]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Framework.].[RestPath]' 'Table/@Name',
								(
									select	ApplicationName 'ApplicationName',
											Resolver 'Resolver'
									from [Framework.].[RestPath]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Framework.].[Job]' 'Table/@Name',
								(
									select	JobID 'JobID',
											JobGroup 'JobGroup',
											Step 'Step',
											IsActive 'IsActive',
											Script 'Script'
									from [Framework.].[Job]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Framework.].[JobGroup]' 'Table/@Name',
								(
									SELECT  JobGroup 'JobGroup',
											Name 'Name',
											Type 'Type',
											Description 'Description'	
									from [Framework.].JobGroup
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					--------------------------------------------------------
					-- [Ontology.]
					--------------------------------------------------------
					(
						select	'[Ontology.].[ClassGroup]' 'Table/@Name',
								(
									select	ClassGroupURI 'ClassGroupURI',
											SortOrder 'SortOrder',
											IsVisible 'IsVisible'
									from [Ontology.].[ClassGroup]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Ontology.].[ClassGroupClass]' 'Table/@Name',
								(
									select	ClassGroupURI 'ClassGroupURI',
											ClassURI 'ClassURI',
											SortOrder 'SortOrder'
									from [Ontology.].[ClassGroupClass]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Ontology.].[ClassProperty]' 'Table/@Name',
								(
									select	ClassPropertyID 'ClassPropertyID',
											Class 'Class',
											NetworkProperty 'NetworkProperty',
											Property 'Property',
											IsDetail 'IsDetail',
											Limit 'Limit',
											IncludeDescription 'IncludeDescription',
											IncludeNetwork 'IncludeNetwork',
											SearchWeight 'SearchWeight',
											CustomDisplay 'CustomDisplay',
											CustomEdit 'CustomEdit',
											ViewSecurityGroup 'ViewSecurityGroup',
											EditSecurityGroup 'EditSecurityGroup',
											EditPermissionsSecurityGroup 'EditPermissionsSecurityGroup',
											EditExistingSecurityGroup 'EditExistingSecurityGroup',
											EditAddNewSecurityGroup 'EditAddNewSecurityGroup',
											EditAddExistingSecurityGroup 'EditAddExistingSecurityGroup',
											EditDeleteSecurityGroup 'EditDeleteSecurityGroup',
											MinCardinality 'MinCardinality',
											MaxCardinality 'MaxCardinality',
											CustomDisplayModule 'CustomDisplayModule',
											CustomEditModule 'CustomEditModule'
									from [Ontology.].ClassProperty
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Ontology.].[DataMap]' 'Table/@Name',
						
								(
									select  DataMapID 'DataMapID',
											DataMapGroup 'DataMapGroup',
											IsAutoFeed 'IsAutoFeed',
											Graph 'Graph',
											Class 'Class',
											NetworkProperty 'NetworkProperty',
											Property 'Property',
											MapTable 'MapTable',
											sInternalType 'sInternalType',
											sInternalID 'sInternalID',
											cClass 'cClass',
											cInternalType 'cInternalType',
											cInternalID 'cInternalID',
											oClass 'oClass',
											oInternalType 'oInternalType',
											oInternalID 'oInternalID',
											oValue 'oValue',
											oDataType 'oDataType',
											oLanguage 'oLanguage',
											oStartDate 'oStartDate',
											oStartDatePrecision 'oStartDatePrecision',
											oEndDate 'oEndDate',
											oEndDatePrecision 'oEndDatePrecision',
											oObjectType 'oObjectType',
											Weight 'Weight',
											OrderBy 'OrderBy',
											ViewSecurityGroup 'ViewSecurityGroup',
											EditSecurityGroup 'EditSecurityGroup',
											_ClassNode '_ClassNode',
											_NetworkPropertyNode '_NetworkPropertyNode',
											_PropertyNode '_PropertyNode'
									from [Ontology.].[DataMap]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Ontology.].[Namespace]' 'Table/@Name',
								(
									select	URI 'URI',
											Prefix 'Prefix'
									from [Ontology.].[Namespace]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Ontology.].[PropertyGroup]' 'Table/@Name',
								(
									select	PropertyGroupURI 'PropertyGroupURI',
											SortOrder 'SortOrder',
											_PropertyGroupLabel '_PropertyGroupLabel',
											_PropertyGroupNode '_PropertyGroupNode',
											_NumberOfNodes '_NumberOfNodes'
									from [Ontology.].[PropertyGroup]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Ontology.].[PropertyGroupProperty]' 'Table/@Name',
								(
									select	PropertyGroupURI 'PropertyGroupURI',
											PropertyURI 'PropertyURI',
											SortOrder 'SortOrder',
											CustomDisplayModule 'CustomDisplayModule',
											CustomEditModule 'CustomEditModule',
											_PropertyGroupNode '_PropertyGroupNode',
											_PropertyNode '_PropertyNode',
											_TagName '_TagName',
											_PropertyLabel '_PropertyLabel',
											_NumberOfNodes '_NumberOfNodes'
									from [Ontology.].[PropertyGroupProperty]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					--------------------------------------------------------
					-- [Ontology.Presentation]
					--------------------------------------------------------
					(
						select	'[Ontology.Presentation].[XML]' 'Table/@Name',
								(
									select	PresentationID 'PresentationID', 
											type 'type',
											subject 'subject',
											predicate 'predicate',
											object 'object',
											presentationXML 'presentationXML'
									from [Ontology.Presentation].[XML]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					--------------------------------------------------------
					-- [RDF.Security]
					--------------------------------------------------------
					(
						select	'[RDF.Security].[Group]' 'Table/@Name',
								(
									select	SecurityGroupID 'SecurityGroupID',
											Label 'Label',
											HasSpecialViewAccess 'HasSpecialViewAccess',
											HasSpecialEditAccess 'HasSpecialEditAccess',
											Description 'Description'
									from [RDF.Security].[Group]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					--------------------------------------------------------
					-- [Utility.NLP]
					--------------------------------------------------------
					(
						select	'[Utility.NLP].[ParsePorterStemming]' 'Table/@Name',
								(
									select	step 'Step',
											Ordering 'Ordering',
											phrase1 'phrase1',
											phrase2 'phrase2'
									from [Utility.NLP].ParsePorterStemming
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Utility.NLP].[StopWord]' 'Table/@Name',
								(
									select	word 'word',
											stem 'stem',
											scope 'scope'
									from [Utility.NLP].[StopWord]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					(
						select	'[Utility.NLP].[Thesaurus.Source]' 'Table/@Name',
								(
									select	Source 'Source',
											SourceName 'SourceName'
									from [Utility.NLP].[Thesaurus.Source]
									for xml path('Row'), type
								) 'Table'
						for xml path(''), type
					),
					--------------------------------------------------------
					-- [User.Session]
					--------------------------------------------------------
					(
						select	'[User.Session].Bot' 'Table/@Name',
							(
								SELECT UserAgent 'UserAgent' 
								  FROM [User.Session].Bot
				  					for xml path('Row'), type
			   				) 'Table'  
						for xml path(''), type
					),
					--------------------------------------------------------
					-- [Direct.]
					--------------------------------------------------------
					(
						select	'[Direct.].[Sites]' 'Table/@Name',
							(
								SELECT SiteID 'SiteID',
										BootstrapURL 'BootstrapURL',
										SiteName 'SiteName',
										QueryURL 'QueryURL',
										SortOrder 'SortOrder',
										IsActive 'IsActive'  
								  FROM [Direct.].[Sites] 
			 					for xml path('Row'), type
					 		) 'Table'   
						for xml path(''), TYPE
					),
					--------------------------------------------------------
					-- [Profile.Data]
					--------------------------------------------------------
					(
						select	'[Profile.Data].[Publication.Type]' 'Table/@Name',
							(
								SELECT	pubidtype_id 'pubidtype_id',
										name 'name',
										sort_order 'sort_order'
								  FROM [Profile.Data].[Publication.Type]
				  					for xml path('Row'), type
			   				) 'Table'  
						for xml path(''), type
					),
					(
						select	'[Profile.Data].[Publication.MyPub.Category]' 'Table/@Name',
							(
								SELECT	HmsPubCategory 'HmsPubCategory',
										CategoryName 'CategoryName'
								  FROM [Profile.Data].[Publication.MyPub.Category]
				  					for xml path('Row'), type
							) 'Table'  
						for xml path(''), type
					)	
				for xml path(''), type
			) 'Import'
		for xml path(''), type
	)

	insert into [Framework.].[InstallData] (Data)
		select @x


   --Use to generate select lists for new tables
   --SELECT    c.name +  ' ''' + name + ''','
   --FROM sys.columns c  
   --WHERE object_id IN (SELECT object_id FROM sys.tables WHERE name = 'Publication.MyPub.Category')  

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Module].[NetworkTimeline.Person.HasResearchArea.GetData]'
GO
ALTER PROCEDURE [Profile.Module].[NetworkTimeline.Person.HasResearchArea.GetData]
	@NodeID BIGINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @PersonID INT
 	SELECT @PersonID = CAST(m.InternalID AS INT)
		FROM [RDF.Stage].[InternalNodeMap] m, [RDF.].Node n
		WHERE m.Status = 3 AND m.ValueHash = n.ValueHash AND n.NodeID = @NodeID
 
 	DECLARE @baseURI NVARCHAR(400)
	SELECT @baseURI = value FROM [Framework.].Parameter WHERE ParameterID = 'baseURI'

	;with a as (
		select t.*, g.pubdate
		from (
			select top 20 *, 
				--numpubsthis/sqrt(numpubsall+100)/sqrt((LastPublicationYear+1 - FirstPublicationYear)*1.00000) w
				--numpubsthis/sqrt(numpubsall+100)/((LastPublicationYear+1 - FirstPublicationYear)*1.00000) w
				--WeightNTA/((LastPublicationYear+2 - FirstPublicationYear)*1.00000) w
				weight w
			from [Profile.Cache].[Concept.Mesh.Person]
			where personid = @PersonID
			order by w desc, meshheader
		) t, [Profile.Cache].[Concept.Mesh.PersonPublication] m, [Profile.Data].[Publication.PubMed.General] g
		where t.meshheader = m.meshheader and t.personid = m.personid and m.pmid = g.pmid and year(g.pubdate) > 1900
	), b as (
		select min(firstpublicationyear)-1 a, max(lastpublicationyear)+1 b,
			cast(cast('1/1/'+cast(min(firstpublicationyear)-1 as varchar(10)) as datetime) as float) f,
			cast(cast('1/1/'+cast(max(lastpublicationyear)+1 as varchar(10)) as datetime) as float) g
		from a
	), c as (
		select a.*, (cast(pubdate as float)-f)/(g-f) x, a, b, f, g
		from a, b
	), d as (
		select meshheader, min(x) MinX, max(x) MaxX, avg(x) AvgX
				--, (select avg(cast(g.pubdate as float))
				--from resnav_people_hmsopen.dbo.pm_pubs_general g, (
				--	select distinct pmid
				--	from resnav_people_hmsopen.dbo.cache_pub_mesh m
				--	where m.meshheader = c.meshheader
				--) t
				--where g.pmid = t.pmid) AvgAllX
		from c
		group by meshheader
	)
	select c.*, d.MinX, d.MaxX, d.AvgX,	c.meshheader label, (select count(distinct meshheader) from a) n, p.DescriptorUI
		into #t
		from c, d, [Profile.Data].[Concept.Mesh.Descriptor] p
		where c.meshheader = d.meshheader and d.meshheader = p.DescriptorName

	select t.*, @baseURI + cast(m.NodeID as varchar(50)) ObjectURI
		from #t t, [RDF.Stage].[InternalNodeMap] m
		where t.DescriptorUI = m.InternalID
			and m.Class = 'http://www.w3.org/2004/02/skos/core#Concept' and m.InternalType = 'MeshDescriptor'
		order by AvgX, firstpublicationyear, lastpublicationyear, meshheader, pubdate

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Search.Cache].[History.UpdateTopSearchPhrase]'
GO
ALTER PROCEDURE [Search.Cache].[History.UpdateTopSearchPhrase]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	CREATE TABLE #TopSearchPhrase (
		TimePeriod CHAR(1) NOT NULL,
		Phrase VARCHAR(100) NOT NULL,
		NumberOfQueries INT
	)

	-- Get top day, week, and month phrases
	
	INSERT INTO #TopSearchPhrase (TimePeriod, Phrase, NumberOfQueries)
		SELECT TOP 10 'd', Phrase, COUNT(*) n
			FROM [Search.].[History.Phrase]
			WHERE NumberOfConnections > 0
				AND LEN(Phrase) <= 100
				AND IsBot = 0
				AND EndDate >= DATEADD(DAY,-1,GETDATE())
			GROUP BY Phrase
			ORDER BY n DESC

	INSERT INTO #TopSearchPhrase (TimePeriod, Phrase, NumberOfQueries)
		SELECT TOP 10 'w', Phrase, COUNT(*) n
			FROM [Search.].[History.Phrase]
			WHERE NumberOfConnections > 0
				AND LEN(Phrase) <= 100
				AND IsBot = 0
				AND EndDate >= DATEADD(WEEK,-1,GETDATE())
			GROUP BY Phrase
			ORDER BY n DESC

	INSERT INTO #TopSearchPhrase (TimePeriod, Phrase, NumberOfQueries)
		SELECT TOP 10 'm', Phrase, COUNT(*) n
			FROM [Search.].[History.Phrase]
			WHERE NumberOfConnections > 0
				AND LEN(Phrase) <= 100
				AND IsBot = 0
				AND EndDate >= DATEADD(MONTH,-1,GETDATE())
			GROUP BY Phrase
			ORDER BY n DESC

	-- Add phrases to try to get to 10 phrases per time period

	DECLARE @n INT
	
	SELECT @n = 10 - (SELECT COUNT(*) FROM #TopSearchPhrase WHERE TimePeriod = 'd')
	IF @n > 0
		INSERT INTO #TopSearchPhrase (TimePeriod, Phrase, NumberOfQueries)
			SELECT TOP(@n) 'd', Phrase, NumberOfQueries
				FROM #TopSearchPhrase
				WHERE TimePeriod = 'w'
					AND Phrase NOT IN (SELECT Phrase FROM #TopSearchPhrase WHERE TimePeriod = 'd')
				ORDER BY NumberOfQueries DESC

	SELECT @n = 10 - (SELECT COUNT(*) FROM #TopSearchPhrase WHERE TimePeriod = 'd')
	IF @n > 0
		INSERT INTO #TopSearchPhrase (TimePeriod, Phrase, NumberOfQueries)
			SELECT TOP(@n) 'd', Phrase, NumberOfQueries
				FROM #TopSearchPhrase
				WHERE TimePeriod = 'm'
					AND Phrase NOT IN (SELECT Phrase FROM #TopSearchPhrase WHERE TimePeriod = 'd')
				ORDER BY NumberOfQueries DESC

	SELECT @n = 10 - (SELECT COUNT(*) FROM #TopSearchPhrase WHERE TimePeriod = 'w')
	IF @n > 0
		INSERT INTO #TopSearchPhrase (TimePeriod, Phrase, NumberOfQueries)
			SELECT TOP(@n) 'w', Phrase, NumberOfQueries
				FROM #TopSearchPhrase
				WHERE TimePeriod = 'm'
					AND Phrase NOT IN (SELECT Phrase FROM #TopSearchPhrase WHERE TimePeriod = 'w')
				ORDER BY NumberOfQueries DESC

	-- Update the cache table

	TRUNCATE TABLE [Search.Cache].[History.TopSearchPhrase]
	INSERT INTO [Search.Cache].[History.TopSearchPhrase] (TimePeriod, Phrase, NumberOfQueries)
		SELECT TimePeriod, Phrase, NumberOfQueries 
			FROM #TopSearchPhrase

	--DROP TABLE #TopSearchPhrase
	--SELECT * FROM [Search.Cache].[History.TopSearchPhrase]
	
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Module].[NetworkAuthorshipTimeline.Concept.GetData]'
GO
ALTER PROCEDURE [Profile.Module].[NetworkAuthorshipTimeline.Concept.GetData]
	@NodeID BIGINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @DescriptorName NVARCHAR(255)
 	SELECT @DescriptorName = d.DescriptorName
		FROM [RDF.Stage].[InternalNodeMap] m, [RDF.].Node n,
			[Profile.Data].[Concept.Mesh.Descriptor] d
		WHERE m.Status = 3 AND m.ValueHash = n.ValueHash AND n.NodeID = @NodeID
			AND m.InternalID = d.DescriptorUI

    -- Insert statements for procedure here
	declare @gc varchar(max)

	declare @y table (
		y int,
		A int,
		B int
	)

	insert into @y (y,A,B)
		select n.n y, coalesce(t.A,0) A, coalesce(t.B,0) B
		from [Utility.Math].[N] left outer join (
			select (case when y < 1970 then 1970 else y end) y,
				sum(A) A,
				sum(B) B
			from (
				select pmid, pubyear y, (case when w = 1 then 1 else 0 end) A, (case when w < 1 then 1 else 0 end) B
				from (
					select distinct pmid, pubyear, topicweight w
					from [Profile.Cache].[Concept.Mesh.PersonPublication]
					where meshheader = @DescriptorName
				) t
			) t
			group by y
		) t on n.n = t.y
		where n.n between 1980 and year(getdate())

	declare @x int

	select @x = max(A+B)
		from @y

	if coalesce(@x,0) > 0
	begin
		declare @v varchar(1000)
		declare @z int
		declare @k int
		declare @i int

		set @z = power(10,floor(log(@x)/log(10)))
		set @k = floor(@x/@z)
		if @x > @z*@k
			select @k = @k + 1
		if @k > 5
			select @k = floor(@k/2.0+0.5), @z = @z*2

		set @v = ''
		set @i = 0
		while @i <= @k
		begin
			set @v = @v + '|' + cast(@z*@i as varchar(50))
			set @i = @i + 1
		end
		set @v = '|0|'+cast(@x as varchar(50))
		--set @v = '|0|50|100'

		declare @h varchar(1000)
		set @h = ''
		select @h = @h + '|' + (case when y % 2 = 1 then '' else ''''+right(cast(y as varchar(50)),2) end)
			from @y
			order by y 

		declare @w float
		--set @w = @k*@z
		set @w = @x

		declare @d varchar(max)
		set @d = ''
		select @d = @d + cast(floor(0.5 + 100*A/@w) as varchar(50)) + ','
			from @y
			order by y
		set @d = left(@d,len(@d)-1) + '|'
		select @d = @d + cast(floor(0.5 + 100*B/@w) as varchar(50)) + ','
			from @y
			order by y
		set @d = left(@d,len(@d)-1)

		declare @c varchar(50)
		set @c = 'FB8072,80B1D3'
		--set @c = 'FB8072,B3DE69,80B1D3'
		--set @c = 'F96452,a8dc4f,68a4cc'
		--set @c = 'fea643,76cbbd,b56cb5'

		--select @v, @h, @d

		--set @gc = '//chart.googleapis.com/chart?chs=595x100&chf=bg,s,ffffff|c,s,ffffff&chxt=x,y&chxl=0:' + @h + '|1:' + @v + '&cht=bvs&chd=t:' + @d + '&chdl=First+Author|Middle or Unkown|Last+Author&chco='+@c+'&chbh=10'
		set @gc = '//chart.googleapis.com/chart?chs=595x100&chf=bg,s,ffffff|c,s,ffffff&chxt=x,y&chxl=0:' + @h + '|1:' + @v + '&cht=bvs&chd=t:' + @d + '&chdl=Major+Topic|Minor+Topic&chco='+@c+'&chbh=10'

		select @gc gc --, @w w

		--select * from @y order by y

	end

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Framework.].[LoadInstallData]'
GO
ALTER procedure [Framework.].[LoadInstallData]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

 DECLARE @x XML
 SELECT @x = ( SELECT TOP 1
                        Data
               FROM     [Framework.].[InstallData]
               ORDER BY InstallDataID DESC
             ) 


---------------------------------------------------------------
-- [Framework.]
---------------------------------------------------------------
 
             
-- [Framework.].[Parameter]
TRUNCATE TABLE [Framework.].[Parameter]
INSERT INTO [Framework.].Parameter
	( ParameterID, Value )        
SELECT	R.x.value('ParameterID[1]', 'varchar(max)') ,
		R.x.value('Value[1]', 'varchar(max)')
FROM    ( SELECT
			@x.query
			('Import[1]/Table[@Name=''[Framework.].[Parameter]'']')
			x
		) t
CROSS APPLY x.nodes('//Row') AS R ( x )

  
       
-- [Framework.].[RestPath] 
INSERT INTO [Framework.].RestPath
        ( ApplicationName, Resolver )   
SELECT  R.x.value('ApplicationName[1]', 'varchar(max)') ,
        R.x.value('Resolver[1]', 'varchar(max)') 
FROM    ( SELECT
                    @x.query
                    ('Import[1]/Table[@Name=''[Framework.].[RestPath]'']')
                    x
        ) t
CROSS APPLY x.nodes('//Row') AS R ( x )

   
--[Framework.].[Job]
INSERT INTO [Framework.].Job
        ( JobID,
		  JobGroup,
          Step,
          IsActive,
          Script
        ) 
SELECT	R.x.value('JobID[1]','varchar(max)'),
		R.x.value('JobGroup[1]','varchar(max)'),
		R.x.value('Step[1]','varchar(max)'),
		R.x.value('IsActive[1]','varchar(max)'),
		R.x.value('Script[1]','varchar(max)')
FROM    ( SELECT
                  @x.query
                  ('Import[1]/Table[@Name=''[Framework.].[Job]'']')
                  x
      ) t
CROSS APPLY x.nodes('//Row') AS R ( x )

	
--[Framework.].[JobGroup]
INSERT INTO [Framework.].JobGroup
        ( JobGroup, Name, Type, Description ) 
SELECT	R.x.value('JobGroup[1]','varchar(max)'),
		R.x.value('Name[1]','varchar(max)'),
		R.x.value('Type[1]','varchar(max)'),
		R.x.value('Description[1]','varchar(max)')
FROM    ( SELECT
                  @x.query
                  ('Import[1]/Table[@Name=''[Framework.].[JobGroup]'']')
                  x
      ) t
CROSS APPLY x.nodes('//Row') AS R ( x )
       
  

---------------------------------------------------------------
-- [Ontology.]
---------------------------------------------------------------
 
 --[Ontology.].[ClassGroup]
 TRUNCATE TABLE [Ontology.].[ClassGroup]
 INSERT INTO [Ontology.].ClassGroup
         ( ClassGroupURI,
           SortOrder,
           IsVisible
         )
  SELECT  R.x.value('ClassGroupURI[1]', 'varchar(max)') ,
          R.x.value('SortOrder[1]', 'varchar(max)'),
          R.x.value('IsVisible[1]', 'varchar(max)')
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[ClassGroup]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x ) 
  
 --[Ontology.].[ClassGroupClass]
 TRUNCATE TABLE [Ontology.].[ClassGroupClass]
 INSERT INTO [Ontology.].ClassGroupClass
         ( ClassGroupURI,
           ClassURI,
           SortOrder
         )
  SELECT  R.x.value('ClassGroupURI[1]', 'varchar(max)') ,
          R.x.value('ClassURI[1]', 'varchar(max)'),
          R.x.value('SortOrder[1]', 'varchar(max)')
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[ClassGroupClass]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )

  
--[Ontology.].[ClassProperty]
INSERT INTO [Ontology.].ClassProperty
        ( ClassPropertyID,
          Class,
          NetworkProperty,
          Property,
          IsDetail,
          Limit,
          IncludeDescription,
          IncludeNetwork,
          SearchWeight,
          CustomDisplay,
          CustomEdit,
          ViewSecurityGroup,
          EditSecurityGroup,
          EditPermissionsSecurityGroup,
          EditExistingSecurityGroup,
          EditAddNewSecurityGroup,
          EditAddExistingSecurityGroup,
          EditDeleteSecurityGroup,
          MinCardinality,
          MaxCardinality,
          CustomDisplayModule,
          CustomEditModule
        )
SELECT  R.x.value('ClassPropertyID[1]','varchar(max)'),
		R.x.value('Class[1]','varchar(max)'),
		R.x.value('NetworkProperty[1]','varchar(max)'),
		R.x.value('Property[1]','varchar(max)'),
		R.x.value('IsDetail[1]','varchar(max)'),
		R.x.value('Limit[1]','varchar(max)'),
		R.x.value('IncludeDescription[1]','varchar(max)'),
		R.x.value('IncludeNetwork[1]','varchar(max)'),
		R.x.value('SearchWeight[1]','varchar(max)'),
		R.x.value('CustomDisplay[1]','varchar(max)'),
		R.x.value('CustomEdit[1]','varchar(max)'),
		R.x.value('ViewSecurityGroup[1]','varchar(max)'),
		R.x.value('EditSecurityGroup[1]','varchar(max)'),
		R.x.value('EditPermissionsSecurityGroup[1]','varchar(max)'),
		R.x.value('EditExistingSecurityGroup[1]','varchar(max)'),
		R.x.value('EditAddNewSecurityGroup[1]','varchar(max)'),
		R.x.value('EditAddExistingSecurityGroup[1]','varchar(max)'),
		R.x.value('EditDeleteSecurityGroup[1]','varchar(max)'),
		R.x.value('MinCardinality[1]','varchar(max)'),
		R.x.value('MaxCardinality[1]','varchar(max)'),
		(case when CAST(R.x.query('CustomDisplayModule[1]/*') AS NVARCHAR(MAX))<>'' then R.x.query('CustomDisplayModule[1]/*') else NULL end),
		(case when CAST(R.x.query('CustomEditModule[1]/*') AS NVARCHAR(MAX))<>'' then R.x.query('CustomEditModule[1]/*') else NULL end)
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[ClassProperty]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )

  
  --[Ontology.].[DataMap]
  TRUNCATE TABLE [Ontology.].DataMap
  INSERT INTO [Ontology.].DataMap
          ( DataMapID,
			DataMapGroup ,
            IsAutoFeed ,
            Graph ,
            Class ,
            NetworkProperty ,
            Property ,
            MapTable ,
            sInternalType ,
            sInternalID ,
            cClass ,
            cInternalType ,
            cInternalID ,
            oClass ,
            oInternalType ,
            oInternalID ,
            oValue ,
            oDataType ,
            oLanguage ,
            oStartDate ,
            oStartDatePrecision ,
            oEndDate ,
            oEndDatePrecision ,
            oObjectType ,
            Weight ,
            OrderBy ,
            ViewSecurityGroup ,
            EditSecurityGroup ,
            [_ClassNode] ,
            [_NetworkPropertyNode] ,
            [_PropertyNode]
          )
  SELECT    R.x.value('DataMapID[1]','varchar(max)'),
			R.x.value('DataMapGroup[1]','varchar(max)'),
			R.x.value('IsAutoFeed[1]','varchar(max)'),
			R.x.value('Graph[1]','varchar(max)'),
			R.x.value('Class[1]','varchar(max)'),
			R.x.value('NetworkProperty[1]','varchar(max)'),
			R.x.value('Property[1]','varchar(max)'),
			R.x.value('MapTable[1]','varchar(max)'),
			R.x.value('sInternalType[1]','varchar(max)'),
			R.x.value('sInternalID[1]','varchar(max)'),
			R.x.value('cClass[1]','varchar(max)'),
			R.x.value('cInternalType[1]','varchar(max)'),
			R.x.value('cInternalID[1]','varchar(max)'),
			R.x.value('oClass[1]','varchar(max)'),
			R.x.value('oInternalType[1]','varchar(max)'),
			R.x.value('oInternalID[1]','varchar(max)'),
			R.x.value('oValue[1]','varchar(max)'),
			R.x.value('oDataType[1]','varchar(max)'),
			R.x.value('oLanguage[1]','varchar(max)'),
			R.x.value('oStartDate[1]','varchar(max)'),
			R.x.value('oStartDatePrecision[1]','varchar(max)'),
			R.x.value('oEndDate[1]','varchar(max)'),
			R.x.value('oEndDatePrecision[1]','varchar(max)'),
			R.x.value('oObjectType[1]','varchar(max)'),
			R.x.value('Weight[1]','varchar(max)'),
			R.x.value('OrderBy[1]','varchar(max)'),
			R.x.value('ViewSecurityGroup[1]','varchar(max)'),
			R.x.value('EditSecurityGroup[1]','varchar(max)'),
			R.x.value('_ClassNode[1]','varchar(max)'),
			R.x.value('_NetworkPropertyNode[1]','varchar(max)'),
			R.x.value('_PropertyNode[1]','varchar(max)')
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[DataMap]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  
  
 -- [Ontology.].[Namespace]
 TRUNCATE TABLE [Ontology.].[Namespace]
 INSERT INTO [Ontology.].[Namespace]
        ( URI ,
          Prefix
        )
  SELECT  R.x.value('URI[1]', 'varchar(max)') ,
          R.x.value('Prefix[1]', 'varchar(max)')
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[Namespace]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  

   --[Ontology.].[PropertyGroup]
   INSERT INTO [Ontology.].PropertyGroup
           ( PropertyGroupURI ,
             SortOrder ,
             [_PropertyGroupLabel] ,
             [_PropertyGroupNode] ,
             [_NumberOfNodes]
           ) 
	SELECT	R.x.value('PropertyGroupURI[1]','varchar(max)'),
			R.x.value('SortOrder[1]','varchar(max)'),
			R.x.value('_PropertyGroupLabel[1]','varchar(max)'), 
			R.x.value('_PropertyGroupNode[1]','varchar(max)'),
			R.x.value('_NumberOfNodes[1]','varchar(max)')
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[PropertyGroup]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  
  
	--[Ontology.].[PropertyGroupProperty]
	INSERT INTO [Ontology.].PropertyGroupProperty
	        ( PropertyGroupURI ,
	          PropertyURI ,
	          SortOrder ,
	          CustomDisplayModule ,
	          CustomEditModule ,
	          [_PropertyGroupNode] ,
	          [_PropertyNode] ,
	          [_TagName] ,
	          [_PropertyLabel] ,
	          [_NumberOfNodes]
	        ) 
	SELECT	R.x.value('PropertyGroupURI[1]','varchar(max)'),
			R.x.value('PropertyURI[1]','varchar(max)'),
			R.x.value('SortOrder[1]','varchar(max)'),
			(case when CAST(R.x.query('CustomDisplayModule[1]/*') AS NVARCHAR(MAX))<>'' then R.x.query('CustomDisplayModule[1]/*') else NULL end),
			(case when CAST(R.x.query('CustomEditModule[1]/*') AS NVARCHAR(MAX))<>'' then R.x.query('CustomEditModule[1]/*') else NULL end),
			R.x.value('_PropertyGroupNode[1]','varchar(max)'),
			R.x.value('_PropertyNode[1]','varchar(max)'),
			R.x.value('_TagName[1]','varchar(max)'),
			R.x.value('_PropertyLabel[1]','varchar(max)'),
			R.x.value('_NumberOfNodes[1]','varchar(max)')
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.].[PropertyGroupProperty]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  

---------------------------------------------------------------
-- [Ontology.Presentation]
---------------------------------------------------------------


 --[Ontology.Presentation].[XML]
 INSERT INTO [Ontology.Presentation].[XML]
         ( PresentationID,
			type ,
           subject ,
           predicate ,
           object ,
           presentationXML ,
           _SubjectNode ,
           _PredicateNode ,
           _ObjectNode
         )       
  SELECT  R.x.value('PresentationID[1]', 'varchar(max)') ,
		  R.x.value('type[1]', 'varchar(max)') ,
          R.x.value('subject[1]', 'varchar(max)'),
          R.x.value('predicate[1]', 'varchar(max)'),
          R.x.value('object[1]', 'varchar(max)'),
          (case when CAST(R.x.query('presentationXML[1]/*') AS NVARCHAR(MAX))<>'' then R.x.query('presentationXML[1]/*') else NULL end) , 
          R.x.value('_SubjectNode[1]', 'varchar(max)'),
          R.x.value('_PredicateNode[1]', 'varchar(max)'),
          R.x.value('_ObjectNode[1]', 'varchar(max)')
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Ontology.Presentation].[XML]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )

  
---------------------------------------------------------------
-- [RDF.Security]
---------------------------------------------------------------
             
 -- [RDF.Security].[Group]
 TRUNCATE TABLE [RDF.Security].[Group]
 INSERT INTO [RDF.Security].[Group]
 
         ( SecurityGroupID ,
           Label ,
           HasSpecialViewAccess ,
           HasSpecialEditAccess ,
           Description
         )
 SELECT   R.x.value('SecurityGroupID[1]', 'varchar(max)') ,
          R.x.value('Label[1]', 'varchar(max)'),
          R.x.value('HasSpecialViewAccess[1]', 'varchar(max)'),
          R.x.value('HasSpecialEditAccess[1]', 'varchar(max)'),
          R.x.value('Description[1]', 'varchar(max)')
  FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[RDF.Security].[Group]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x ) 



---------------------------------------------------------------
-- [Utility.NLP]
---------------------------------------------------------------
   
	--[Utility.NLP].[ParsePorterStemming]
	INSERT INTO [Utility.NLP].ParsePorterStemming
	        ( Step, Ordering, phrase1, phrase2 ) 
	SELECT	R.x.value('Step[1]','varchar(max)'),
			R.x.value('Ordering[1]','varchar(max)'), 
			R.x.value('phrase1[1]','varchar(max)'), 
			R.x.value('phrase2[1]','varchar(max)')
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Utility.NLP].[ParsePorterStemming]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
	
	--[Utility.NLP].[StopWord]
	INSERT INTO [Utility.NLP].StopWord
	        ( word, stem, scope ) 
	SELECT	R.x.value('word[1]','varchar(max)'),
			R.x.value('stem[1]','varchar(max)'),
			R.x.value('scope[1]','varchar(max)')
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Utility.NLP].[StopWord]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  
	--[Utility.NLP].[Thesaurus.Source]
	INSERT INTO [Utility.NLP].[Thesaurus.Source]
	        ( Source, SourceName ) 
	SELECT	R.x.value('Source[1]','varchar(max)'),
			R.x.value('SourceName[1]','varchar(max)')
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Utility.NLP].[Thesaurus.Source]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )


---------------------------------------------------------------
-- [User.Session]
---------------------------------------------------------------

  --[User.Session].Bot		
  INSERT INTO [User.Session].Bot  ( UserAgent )
   SELECT	R.x.value('UserAgent[1]','varchar(max)') 
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[User.Session].Bot'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  
  
  
---------------------------------------------------------------
-- [Direct.]
---------------------------------------------------------------
   
  --[Direct.].[Sites]
  INSERT INTO [Direct.].[Sites]
          ( SiteID ,
            BootstrapURL ,
            SiteName ,
            QueryURL ,
            SortOrder ,
            IsActive
          )
  SELECT	R.x.value('SiteID[1]','varchar(max)'),
			R.x.value('BootstrapURL[1]','varchar(max)'),
			R.x.value('SiteName[1]','varchar(max)'),
			R.x.value('QueryURL[1]','varchar(max)'),
			R.x.value('SortOrder[1]','varchar(max)'),
			R.x.value('IsActive[1]','varchar(max)')
	 FROM    ( SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Direct.].[Sites]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
	
	
---------------------------------------------------------------
-- [Profile.Data]
---------------------------------------------------------------
 
    --[Profile.Data].[Publication.Type]		
  INSERT INTO [Profile.Data].[Publication.Type]
          ( pubidtype_id, name, sort_order )
           
   SELECT	R.x.value('pubidtype_id[1]','varchar(max)'),
			R.x.value('name[1]','varchar(max)'),
			R.x.value('sort_order[1]','varchar(max)')
	 FROM    (SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Profile.Data].[Publication.Type]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
   
  --[Profile.Data].[Publication.MyPub.Category]
  TRUNCATE TABLE [Profile.Data].[Publication.MyPub.Category]
  INSERT INTO [Profile.Data].[Publication.MyPub.Category]
          ( [HmsPubCategory] ,
            [CategoryName]
          ) 
   SELECT	R.x.value('HmsPubCategory[1]','varchar(max)'),
			R.x.value('CategoryName[1]','varchar(max)')
	 FROM    (SELECT
                      @x.query
                      ('Import[1]/Table[@Name=''[Profile.Data].[Publication.MyPub.Category]'']')
                      x
          ) t
  CROSS APPLY x.nodes('//Row') AS R ( x )
  
  
  -- Use to generate select lists for new tables
  -- SELECT   'R.x.value(''' + c.name +  '[1]'',' + '''varchar(max)'')'+ ',' ,* 
  -- FROM sys.columns c 
  -- JOIN  sys.types t ON t.system_type_id = c.system_type_id 
  -- WHERE object_id IN (SELECT object_id FROM sys.tables WHERE name = 'Publication.MyPub.Category') 
  -- AND T.NAME<>'sysname'ORDER BY c.column_id
	 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Module].[NetworkCloud.Person.HasResearchArea.GetXML]'
GO
-- Stored Procedure

CREATE PROCEDURE [Profile.Module].[NetworkCloud.Person.HasResearchArea.GetXML]
	@NodeID BIGINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @baseURI NVARCHAR(400)
	SELECT @baseURI = value FROM [Framework.].Parameter WHERE ParameterID = 'baseURI'

	DECLARE @hasResearchAreaID BIGINT
	SELECT @hasResearchAreaID = [RDF.].fnURI2NodeID('http://vivoweb.org/ontology/core#hasResearchArea')	

	DECLARE @labelID BIGINT
	SELECT @labelID = [RDF.].fnURI2NodeID('http://www.w3.org/2000/01/rdf-schema#label')	

	SELECT (
		SELECT	'' "@Description",
				'In this concept ''cloud'', the sizes of the concepts are based not only on the number of corresponding publications, but also how relevant the concepts are to the overall topics of the publications, how long ago the publications were written, whether the person was the first or senior author, and how many other people have written about the same topic. The largest concepts are those that are most unique to this person.' "@InfoCaption",
				2 "@Columns",
				(
					SELECT	Value "@ItemURLText", 
							SortOrder "@sortOrder", 
							(CASE WHEN SortOrder <= 5 THEN 'big'
								WHEN Quintile = 1 THEN 'big'
								WHEN Quintile = 5 THEN 'small'
								ELSE 'med' END) "@Weight",
							URI "@ItemURL"
					FROM (
						SELECT t.SortOrder, t.Weight, @baseURI+CAST(t.Object AS VARCHAR(50)) URI, n.Value,
							NTILE(5) OVER (ORDER BY t.SortOrder) Quintile
						FROM [RDF.].[Triple] t
							INNER JOIN [RDF.].[Triple] l
								ON t.Object = l.Subject AND l.Predicate = @labelID
							INNER JOIN [RDF.].[Node] n
								ON l.Object = n.NodeID
						WHERE t.Subject = @NodeID AND t.Predicate = @hasResearchAreaID
					) t
					ORDER BY Value
					FOR XML PATH('Item'), TYPE
				)
		FOR XML PATH('ListView'), TYPE
	) ListViewXML

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Module].[NetworkCategory.Person.HasResearchArea.GetXML]'
GO
-- Stored Procedure

CREATE PROCEDURE [Profile.Module].[NetworkCategory.Person.HasResearchArea.GetXML]
	@NodeID BIGINT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @baseURI NVARCHAR(400)
	SELECT @baseURI = value FROM [Framework.].Parameter WHERE ParameterID = 'baseURI'

	DECLARE @hasResearchAreaID BIGINT
	SELECT @hasResearchAreaID = [RDF.].fnURI2NodeID('http://vivoweb.org/ontology/core#hasResearchArea')	

	DECLARE @labelID BIGINT
	SELECT @labelID = [RDF.].fnURI2NodeID('http://www.w3.org/2000/01/rdf-schema#label')	

	DECLARE @meshSemanticGroupNameID BIGINT
	SELECT @meshSemanticGroupNameID = [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#meshSemanticGroupName')	

	SELECT *
		INTO #t
		FROM (
			SELECT t.SortOrder, t.Weight, @baseURI+CAST(t.Object AS VARCHAR(50)) URI, n.Value Concept, m.Value Category,
				ROW_NUMBER() OVER (PARTITION BY s.Object ORDER BY t.Weight DESC) CategoryRank
			FROM [RDF.].[Triple] t
				INNER JOIN [RDF.].[Triple] l
					ON t.Object = l.Subject AND l.Predicate = @labelID
				INNER JOIN [RDF.].[Node] n
					ON l.Object = n.NodeID
				INNER JOIN [RDF.].[Triple] s
					ON t.Object = s.Subject AND s.Predicate = @meshSemanticGroupNameID
				INNER JOIN [RDF.].[Node] m
					ON s.Object = m.NodeID
			WHERE t.Subject = @NodeID AND t.Predicate = @hasResearchAreaID
		) t
		WHERE CategoryRank <= 10

	SELECT (
		SELECT	'Concepts listed here are grouped according to their ''semantic'' categories. Within each category, up to ten concepts are shown, in decreasing order of relevance.' "@InfoCaption",
				(
					SELECT a.Category "DetailList/@Category",
						(SELECT	'' "Item/@ItemURLText",
								URI "Item/@URL",
								Concept "Item"
							FROM #t b
							WHERE b.Category = a.Category
							ORDER BY b.CategoryRank
							FOR XML PATH(''), TYPE
						) "DetailList"
					FROM (SELECT DISTINCT Category FROM #t) a
					ORDER BY a.Category
					FOR XML PATH(''), TYPE
				)
		FOR XML PATH('Items'), TYPE
	) ItemsXML

END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Import].[LoadProfilesData]'
GO
-- Stored Procedure

/*

Copyright (c) 2008-2010 by the President and Fellows of Harvard College. All rights reserved.  Profiles Research Networking Software was developed under the supervision of Griffin M Weber, MD, PhD., and Harvard Catalyst: The Harvard Clinical and Translational Science Center, with support from the National Center for Research Resources and Harvard University.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
    * Neither the name "Harvard" nor the names of its contributors nor the name "Harvard Catalyst" may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER (PRESIDENT AND FELLOWS OF HARVARD COLLEGE) AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.




*/
ALTER procedure [Profile.Import].[LoadProfilesData]
    (
      @use_internalusername_as_pkey BIT = 0
    )
AS 
    BEGIN
        SET NOCOUNT ON;	


	-- Start Transaction. Log load failures, roll back transaction on error.
        BEGIN TRY
            BEGIN TRAN				 

            DECLARE @ErrMsg NVARCHAR(4000) ,
                @ErrSeverity INT


						-- Department
            INSERT  INTO [Profile.Data].[Organization.Department]
                    ( departmentname ,
                      visible
                    )
                    SELECT DISTINCT
                            departmentname ,
                            1
                    FROM    [Profile.Import].PersonAffiliation a
                    WHERE   departmentname IS NOT NULL
                            AND departmentname NOT IN (
                            SELECT  departmentname
                            FROM    [Profile.Data].[Organization.Department] )


						-- institution
            INSERT  INTO [Profile.Data].[Organization.Institution]
                    ( InstitutionName ,
                      InstitutionAbbreviation
										
                    )
                    SELECT  INSTITUTIONNAME ,
                            INSTITUTIONABBREVIATION
                    FROM    ( SELECT    INSTITUTIONNAME ,
                                        INSTITUTIONABBREVIATION ,
                                        COUNT(*) CNT ,
                                        ROW_NUMBER() OVER ( PARTITION BY institutionname ORDER BY SUM(CASE
                                                              WHEN INSTITUTIONABBREVIATION = ''
                                                              THEN 0
                                                              ELSE 1
                                                              END) DESC ) rank
                              FROM      [Profile.Import].PersonAffiliation
                              GROUP BY  INSTITUTIONNAME ,
                                        INSTITUTIONABBREVIATION
                            ) A
                    WHERE   rank = 1
                            AND institutionname <> ''
                            AND NOT EXISTS ( SELECT b.institutionname
                                             FROM   [Profile.Data].[Organization.Institution] b
                                             WHERE  b.institutionname = a.institutionname )


						-- division
            INSERT  INTO [Profile.Data].[Organization.Division]
                    ( DivisionName  
										
                    )
                    SELECT DISTINCT
                            divisionname
                    FROM    [Profile.Import].PersonAffiliation a
                    WHERE   divisionname IS NOT NULL
                            AND NOT EXISTS ( SELECT b.divisionname
                                             FROM   [Profile.Data].[Organization.Division] b
                                             WHERE  b.divisionname = a.divisionname )

						-- Flag deleted people
            UPDATE  [Profile.Data].Person
            SET     ISactive = 0
            WHERE   internalusername NOT IN (
                    SELECT  internalusername
                    FROM    [Profile.Import].Person )

					-- Update person/user records where data has changed. 
            UPDATE  p
            SET     p.firstname = lp.firstname ,
                    p.lastname = lp.lastname ,
                    p.middlename = lp.middlename ,
                    p.displayname = lp.displayname ,
                    p.suffix = lp.suffix ,
                    p.addressline1 = lp.addressline1 ,
                    p.addressline2 = lp.addressline2 ,
                    p.addressline3 = lp.addressline3 ,
                    p.addressline4 = lp.addressline4 ,
                    p.city = lp.city ,
                    p.state = lp.state ,
                    p.zip = lp.zip ,
                    p.building = lp.building ,
                    p.room = lp.room ,
                    p.phone = lp.phone ,
                    p.fax = lp.fax ,
                    p.EmailAddr = lp.EmailAddr ,
                    p.AddressString = lp.AddressString ,
                    p.isactive = lp.isactive ,
                    p.visible = lp.isvisible
            FROM    [Profile.Data].Person p
                    JOIN [Profile.Import].Person lp ON lp.internalusername = p.internalusername
                                                       AND ( ISNULL(lp.firstname,
                                                              '') <> ISNULL(p.firstname,
                                                              '')
                                                             OR ISNULL(lp.lastname,
                                                              '') <> ISNULL(p.lastname,
                                                              '')
                                                             OR ISNULL(lp.middlename,
                                                              '') <> ISNULL(p.middlename,
                                                              '')
                                                             OR ISNULL(lp.displayname,
                                                              '') <> ISNULL(p.displayname,
                                                              '')
                                                             OR ISNULL(lp.suffix,
                                                              '') <> ISNULL(p.suffix,
                                                              '')
                                                             OR ISNULL(lp.addressline1,
                                                              '') <> ISNULL(p.addressline1,
                                                              '')
                                                             OR ISNULL(lp.addressline2,
                                                              '') <> ISNULL(p.addressline2,
                                                              '')
                                                             OR ISNULL(lp.addressline3,
                                                              '') <> ISNULL(p.addressline3,
                                                              '')
                                                             OR ISNULL(lp.addressline4,
                                                              '') <> ISNULL(p.addressline4,
                                                              '')
                                                             OR ISNULL(lp.city,
                                                              '') <> ISNULL(p.city,
                                                              '')
                                                             OR ISNULL(lp.state,
                                                              '') <> ISNULL(p.state,
                                                              '')
                                                             OR ISNULL(lp.zip,
                                                              '') <> ISNULL(p.zip,
                                                              '')
                                                             OR ISNULL(lp.building,
                                                              '') <> ISNULL(p.building,
                                                              '')
                                                             OR ISNULL(lp.room,
                                                              '') <> ISNULL(p.room,
                                                              '')
                                                             OR ISNULL(lp.phone,
                                                              '') <> ISNULL(p.phone,
                                                              '')
                                                             OR ISNULL(lp.fax,
                                                              '') <> ISNULL(p.fax,
                                                              '')
                                                             OR ISNULL(lp.EmailAddr,
                                                              '') <> ISNULL(p.EmailAddr,
                                                              '')
                                                             OR ISNULL(lp.AddressString,
                                                              '') <> ISNULL(p.AddressString,
                                                              '')
                                                             OR ISNULL(lp.Isactive,
                                                              '') <> ISNULL(p.Isactive,
                                                              '')
                                                             OR ISNULL(lp.isvisible,
                                                              '') <> ISNULL(p.visible,
                                                              '')
                                                           ) 
						-- Update changed user info
            UPDATE  u
            SET     u.firstname = up.firstname ,
                    u.lastname = up.lastname ,
                    u.displayname = up.displayname ,
                    u.institution = up.institution ,
                    u.department = up.department ,
                    u.emailaddr = up.emailaddr
            FROM    [User.Account].[User] u
                    JOIN [Profile.Import].[User] up ON up.internalusername = u.internalusername
                                                       AND ( ISNULL(up.firstname,
                                                              '') <> ISNULL(u.firstname,
                                                              '')
                                                             OR ISNULL(up.lastname,
                                                              '') <> ISNULL(u.lastname,
                                                              '')
                                                             OR ISNULL(up.displayname,
                                                              '') <> ISNULL(u.displayname,
                                                              '')
                                                             OR ISNULL(up.institution,
                                                              '') <> ISNULL(u.institution,
                                                              '')
                                                             OR ISNULL(up.department,
                                                              '') <> ISNULL(u.department,
                                                              '')
                                                             OR ISNULL(up.emailaddr,
                                                              '') <> ISNULL(u.emailaddr,
                                                              '')
                                                           )

					-- Remove Affiliations that have changed, so they'll be re-added
            SELECT DISTINCT
                    COALESCE(p.internalusername, pa.internalusername) internalusername
            INTO    #affiliations
            FROM    [Profile.Cache].[Person.Affiliation] cpa
            JOIN	[Profile.Data].Person p ON p.personid = cpa.personid
       FULL JOIN	[Profile.Import].PersonAffiliation pa ON pa.internalusername = p.internalusername
                                                              AND  pa.affiliationorder =  cpa.sortorder  
                                                              AND pa.primaryaffiliation = cpa.isprimary  
                                                              AND pa.title = cpa.title  
                                                              AND pa.institutionabbreviation =  cpa.institutionabbreviation  
                                                              AND pa.departmentname =  cpa.departmentname  
                                                              AND pa.divisionname = cpa.divisionname 
                                                              AND pa.facultyrank  = cpa.facultyrank
                                                              
            WHERE   pa.internalusername IS NULL
                    OR cpa.personid IS NULL

            DELETE  FROM [Profile.Data].[Person.Affiliation]
            WHERE   personid IN ( SELECT    personid
                                  FROM      [Profile.Data].Person
                                  WHERE     internalusername IN ( SELECT
                                                              internalusername
                                                              FROM
                                                              #affiliations ) )

					-- Remove Filters that have changed, so they'll be re-added
            SELECT  internalusername ,
                    personfilter
            INTO    #filter
            FROM    [Profile.Data].[Person.FilterRelationship] pfr
                    JOIN [Profile.Data].Person p ON p.personid = pfr.personid
                    JOIN [Profile.Data].[Person.Filter] pf ON pf.personfilterid = pfr.personfilterid
            CREATE CLUSTERED INDEX tmp ON #filter(internalusername)
            DELETE  FROM [Profile.Data].[Person.FilterRelationship]
            WHERE   personid IN (
                    SELECT  personid
                    FROM    [Profile.Data].Person
                    WHERE   InternalUsername IN (
                            SELECT  COALESCE(a.internalusername,
                                             p.internalusername)
                            FROM    [Profile.Import].PersonFilterFlag pf
                                    JOIN [Profile.Import].Person p ON p.internalusername = pf.internalusername
                                    FULL JOIN #filter a ON a.internalusername = p.internalusername
                                                           AND a.personfilter = pf.personfilter
                            WHERE   a.internalusername IS NULL
                                    OR p.internalusername IS NULL ) )






					-- user
            IF @use_internalusername_as_pkey = 0 
                BEGIN
                    INSERT  INTO [User.Account].[User]
                            ( IsActive ,
                              CanBeProxy ,
                              FirstName ,
                              LastName ,
                              DisplayName ,
                              Institution ,
                              Department ,
                              InternalUserName ,
                              emailaddr 
						        
                            )
                            SELECT  1 ,
                                    canbeproxy ,
                                    ISNULL(firstname, '') ,
                                    ISNULL(lastname, '') ,
                                    ISNULL(displayname, '') ,
                                    institution ,
                                    department ,
                                    InternalUserName ,
                                    emailaddr
                            FROM    [Profile.Import].[User] u
                            WHERE   NOT EXISTS ( SELECT *
                                                 FROM   [User.Account].[User] b
                                                 WHERE  b.internalusername = u.internalusername )
                            UNION
                            SELECT  1 ,
                                    1 ,
                                    ISNULL(firstname, '') ,
                                    ISNULL(lastname, '') ,
                                    ISNULL(displayname, '') ,
                                    institutionname ,
                                    departmentname ,
                                    u.InternalUserName ,
                                    u.emailaddr
                            FROM    [Profile.Import].Person u
                                    LEFT JOIN [Profile.Import].PersonAffiliation pa ON pa.internalusername = u.internalusername
                                                              AND pa.primaryaffiliation = 1
                            WHERE   NOT EXISTS ( SELECT *
                                                 FROM   [User.Account].[User] b
                                                 WHERE  b.internalusername = u.internalusername )
                END
            ELSE 
                BEGIN
                    SET IDENTITY_INSERT [User.Account].[User] ON 

                    INSERT  INTO [User.Account].[User]
                            ( userid ,
                              IsActive ,
                              CanBeProxy ,
                              FirstName ,
                              LastName ,
                              DisplayName ,
                              Institution ,
                              Department ,
                              InternalUserName ,
                              emailaddr 
						        
                            )
                            SELECT  u.internalusername ,
                                    1 ,
                                    canbeproxy ,
                                    ISNULL(firstname, '') ,
                                    ISNULL(lastname, '') ,
                                    ISNULL(displayname, '') ,
                                    institution ,
                                    department ,
                                    InternalUserName ,
                                    emailaddr
                            FROM    [Profile.Import].[User] u
                            WHERE   NOT EXISTS ( SELECT *
                                                 FROM   [User.Account].[User] b
                                                 WHERE  b.internalusername = u.internalusername )
                            UNION ALL
                            SELECT  u.internalusername ,
                                    1 ,
                                    1 ,
                                    ISNULL(firstname, '') ,
                                    ISNULL(lastname, '') ,
                                    ISNULL(displayname, '') ,
                                    institutionname ,
                                    departmentname ,
                                    u.InternalUserName ,
                                    u.emailaddr
                            FROM    [Profile.Import].Person u
                                    LEFT JOIN [Profile.Import].PersonAffiliation pa ON pa.internalusername = u.internalusername
                                                              AND pa.primaryaffiliation = 1
                            WHERE   NOT EXISTS ( SELECT *
                                                 FROM   [User.Account].[User] b
                                                 WHERE  b.internalusername = u.internalusername )
                                    AND NOT EXISTS ( SELECT *
                                                     FROM   [Profile.Import].[User] b
                                                     WHERE  b.internalusername = u.internalusername )

                    SET IDENTITY_INSERT [User.Account].[User] OFF
                END

					-- faculty ranks
            INSERT  INTO [Profile.Data].[Person.FacultyRank]
                    ( FacultyRank ,
                      FacultyRankSort ,
                      Visible
					        
                    )
                    SELECT DISTINCT
                            facultyrank ,
                            facultyrankorder ,
                            1
                    FROM    [Profile.Import].PersonAffiliation p
                    WHERE   NOT EXISTS ( SELECT *
                                         FROM   [Profile.Data].[Person.FacultyRank] a
                                         WHERE  a.facultyrank = p.facultyrank )

					-- person
            IF @use_internalusername_as_pkey = 0 
                BEGIN				
                    INSERT  INTO [Profile.Data].Person
                            ( UserID ,
                              FirstName ,
                              LastName ,
                              MiddleName ,
                              DisplayName ,
                              Suffix ,
                              IsActive ,
                              EmailAddr ,
                              Phone ,
                              Fax ,
                              AddressLine1 ,
                              AddressLine2 ,
                              AddressLine3 ,
                              AddressLine4 ,
                              city ,
                              state ,
                              zip ,
                              Building ,
                              Floor ,
                              Room ,
                              AddressString ,
                              Latitude ,
                              Longitude ,
                              FacultyRankID ,
                              InternalUsername ,
                              Visible
						        
                            )
                            SELECT  UserID ,
                                    ISNULL(p.FirstName, '') ,
                                    ISNULL(p.LastName, '') ,
                                    ISNULL(p.MiddleName, '') ,
                                    ISNULL(p.DisplayName, '') ,
                                    ISNULL(Suffix, '') ,
                                    p.IsActive ,
                                    p.EmailAddr ,
                                    Phone ,
                                    Fax ,
                                    AddressLine1 ,
                                    AddressLine2 ,
                                    AddressLine3 ,
                                    AddressLine4 ,
                                    city ,
                                    state ,
                                    zip ,
                                    Building ,
                                    Floor ,
                                    Room ,
                                    AddressString ,
                                    Latitude ,
                                    Longitude ,
                                    FacultyRankID ,
                                    p.InternalUsername ,
                                    p.isvisible
                            FROM    [Profile.Import].Person p
                                    OUTER APPLY ( SELECT TOP 1
                                                            internalusername ,
                                                            facultyrankid ,
                                                            facultyranksort
                                                  FROM      [Profile.import].[PersonAffiliation] pa
                                                            JOIN [Profile.Data].[Person.FacultyRank] fr ON fr.facultyrank = pa.facultyrank
                                                  WHERE     pa.internalusername = p.internalusername
                                                  ORDER BY  facultyranksort ASC
                                                ) a
                                    JOIN [User.Account].[User] u ON u.internalusername = p.internalusername
                            WHERE   NOT EXISTS ( SELECT *
                                                 FROM   [Profile.Data].Person b
                                                 WHERE  b.internalusername = p.internalusername )   
                END
            ELSE 
                BEGIN
                    SET IDENTITY_INSERT [Profile.Data].Person ON
                    INSERT  INTO [Profile.Data].Person
                            ( personid ,
                              UserID ,
                              FirstName ,
                              LastName ,
                              MiddleName ,
                              DisplayName ,
                              Suffix ,
                              IsActive ,
                              EmailAddr ,
                              Phone ,
                              Fax ,
                              AddressLine1 ,
                              AddressLine2 ,
                              AddressLine3 ,
                              AddressLine4 ,
                              Building ,
                              Floor ,
                              Room ,
                              AddressString ,
                              Latitude ,
                              Longitude ,
                              FacultyRankID ,
                              InternalUsername ,
                              Visible
						        
                            )
                            SELECT  p.internalusername ,
                                    userid ,
                                    ISNULL(p.FirstName, '') ,
                                    ISNULL(p.LastName, '') ,
                                    ISNULL(p.MiddleName, '') ,
                                    ISNULL(p.DisplayName, '') ,
                                    ISNULL(Suffix, '') ,
                                    p.IsActive ,
                                    p.EmailAddr ,
                                    Phone ,
                                    Fax ,
                                    AddressLine1 ,
                                    AddressLine2 ,
                                    AddressLine3 ,
                                    AddressLine4 ,
                                    Building ,
                                    Floor ,
                                    Room ,
                                    AddressString ,
                                    Latitude ,
                                    Longitude ,
                                    FacultyRankID ,
                                    p.InternalUsername ,
                                    p.isvisible
                            FROM    [Profile.Import].Person p
                                    OUTER APPLY ( SELECT TOP 1
                                                            internalusername ,
                                                            facultyrankid ,
                                                            facultyranksort
                                                  FROM      [Profile.import].[PersonAffiliation] pa
                                                            JOIN [Profile.Data].[Person.FacultyRank] fr ON fr.facultyrank = pa.facultyrank
                                                  WHERE     pa.internalusername = p.internalusername
                                                  ORDER BY  facultyranksort ASC
                                                ) a
                                    JOIN [User.Account].[User] u ON u.internalusername = p.internalusername
                            WHERE   NOT EXISTS ( SELECT *
                                                 FROM   [Profile.Data].Person b
                                                 WHERE  b.internalusername = p.internalusername )  
                    SET IDENTITY_INSERT [Profile.Data].Person OFF

                END

						-- add personid to user
            UPDATE  u
            SET     u.personid = p.personid
            FROM    [Profile.Data].Person p
                    JOIN [User.Account].[User] u ON u.userid = p.userid


					-- person affiliation
            INSERT  INTO [Profile.Data].[Person.Affiliation]
                    ( PersonID ,
                      SortOrder ,
                      IsActive ,
                      IsPrimary ,
                      InstitutionID ,
                      DepartmentID ,
                      DivisionID ,
                      Title ,
                      EmailAddress ,
                      FacultyRankID
					        
                    )
                    SELECT  p.personid ,
                            affiliationorder ,
                            1 ,
                            primaryaffiliation ,
                            InstitutionID ,
                            DepartmentID ,
                            DivisionID ,
                            c.title ,
                            c.emailaddr ,
                            fr.facultyrankid
                    FROM    [Profile.Import].PersonAffiliation c
                            JOIN [Profile.Data].Person p ON c.internalusername = p.internalusername
                            LEFT JOIN [Profile.Data].[Organization.Institution] i ON i.institutionname = c.institutionname
                            LEFT JOIN [Profile.Data].[Organization.Department] d ON d.departmentname = c.departmentname
                            LEFT JOIN [Profile.Data].[Organization.Division] di ON di.divisionname = c.divisionname
                            LEFT JOIN [Profile.Data].[Person.FacultyRank] fr ON fr.facultyrank = c.facultyrank
                    WHERE   NOT EXISTS ( SELECT *
                                         FROM   [Profile.Data].[Person.Affiliation] a
                                         WHERE  a.personid = p.personid
                                                AND ISNULL(a.InstitutionID, '') = ISNULL(i.InstitutionID,
                                                              '')
                                                AND ISNULL(a.DepartmentID, '') = ISNULL(d.DepartmentID,
                                                              '')
                                                AND ISNULL(a.DivisionID, '') = ISNULL(di.DivisionID,
                                                              '') )


					-- person_filters
            INSERT  INTO [Profile.Data].[Person.Filter]
                    ( PersonFilter 
					        
                    )
                    SELECT DISTINCT
                            personfilter
                    FROM    [Profile.Import].PersonFilterFlag b
                    WHERE   NOT EXISTS ( SELECT *
                                         FROM   [Profile.Data].[Person.Filter] a
                                         WHERE  a.personfilter = b.personfilter )


				-- person_filter_relationships
            INSERT  INTO [Profile.Data].[Person.FilterRelationship]
                    ( PersonID ,
                      PersonFilterid
					        
                    )
                    SELECT DISTINCT
                            p.personid ,
                            personfilterid
                    FROM    [Profile.Import].PersonFilterFlag ptf
                            JOIN [Profile.Data].[Person.Filter] pt ON pt.personfilter = ptf.personfilter
                            JOIN [Profile.Data].Person p ON p.internalusername = ptf.internalusername
                    WHERE   NOT EXISTS ( SELECT *
                                         FROM   [Profile.Data].[Person.FilterRelationship] ptf
                                                JOIN [Profile.Data].[Person.Filter] pt2 ON pt2.personfilterid = ptf.personfilterid
                                                JOIN [Profile.Data].Person p2 ON p2.personid = ptf.personid
                                         WHERE  ( p2.personid = p.personid
                                                  AND pt.personfilterid = pt2.personfilterid
                                                ) )												     										     

			-- update changed affiliation in person table
            UPDATE  p
            SET     facultyrankid = a.facultyrankid
            FROM    [Profile.Data].person p
                    OUTER APPLY ( SELECT TOP 1
                                            internalusername ,
                                            facultyrankid ,
                                            facultyranksort
                                  FROM      [Profile.import].[PersonAffiliation] pa
                                            JOIN [Profile.Data].[Person.FacultyRank] fr ON fr.facultyrank = pa.facultyrank
                                  WHERE     pa.internalusername = p.internalusername
                                  ORDER BY  facultyranksort ASC
                                ) a
            WHERE   p.facultyrankid <> a.facultyrankid
			 
			 
			-- Hide/Show Departments
            UPDATE  d
            SET     d.visible = ISNULL(t.v, 0)
            FROM    [Profile.Data].[Organization.Department] d
                    LEFT OUTER JOIN ( SELECT    a.departmentname ,
                                                MAX(CAST(a.departmentvisible AS INT)) v
                                      FROM      [Profile.Import].PersonAffiliation a ,
                                                [Profile.Import].Person p
                                      WHERE     a.internalusername = p.internalusername
                                                AND p.isactive = 1
                                      GROUP BY  a.departmentname
                                    ) t ON d.departmentname = t.departmentname


			-- Apply person active changes to user table
			UPDATE u 
			   SET isactive  = p.isactive
			  FROM [User.Account].[User] u 
			  JOIN [Profile.Data].Person p ON p.PersonID = u.PersonID 
			  
            COMMIT
        END TRY
        BEGIN CATCH
			--Check success
            IF @@TRANCOUNT > 0 
                ROLLBACK

			-- Raise an error with the details of the exception
            SELECT  @ErrMsg = ERROR_MESSAGE() ,
                    @ErrSeverity = ERROR_SEVERITY()

            RAISERROR(@ErrMsg, @ErrSeverity, 1)
        END CATCH	

    END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Cache].[Concept.Mesh.UpdateTreeTop]'
GO
CREATE PROCEDURE [Profile.Cache].[Concept.Mesh.UpdateTreeTop]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
 
	DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int
	DECLARE @proc VARCHAR(200)
	SELECT @proc = OBJECT_NAME(@@PROCID)
	DECLARE @date DATETIME,@auditid UNIQUEIDENTIFIER, @rows int
	SELECT @date=GETDATE() 
	EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@proc,@ProcessStartDate=@date,@insert_new_record=1
 
 	select r.TreeNumber FullTreeNumber, 
			(case when len(r.TreeNumber)=1 then '' else left(r.TreeNumber,len(r.TreeNumber)-4) end) ParentTreeNumber,
			r.DescriptorName, IsNull(t.TreeNumber,r.TreeNumber) TreeNumber, t.DescriptorUI
		into #TreeTop
		from [Profile.Data].[Concept.Mesh.TreeTop] r
			left outer join [Profile.Data].[Concept.Mesh.Tree] t
				on t.TreeNumber = substring(r.TreeNumber,3,999)
			left outer join [Framework.].[Parameter] f
				on f.ParameterID = 'baseURI'
 
	BEGIN TRY
		BEGIN TRAN
			TRUNCATE TABLE [Profile.Cache].[Concept.Mesh.TreeTop]
			INSERT INTO [Profile.Cache].[Concept.Mesh.TreeTop] (FullTreeNumber, ParentTreeNumber, TreeNumber, DescriptorName, DescriptorUI)
				SELECT FullTreeNumber, ParentTreeNumber, TreeNumber, DescriptorName, DescriptorUI
				FROM #TreeTop
			SELECT @rows = @@ROWCOUNT
		COMMIT
	END TRY
	BEGIN CATCH
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
		SELECT @date=GETDATE()
		EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@proc,@ProcessEndDate=@date,@error = 1,@insert_new_record=0
		--Raise an error with the details of the exception
		SELECT @ErrMsg = ERROR_MESSAGE(), @ErrSeverity = ERROR_SEVERITY()
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
	END CATCH
 
	SELECT @date=GETDATE()
	EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName ='Concept.Mesh.UpdateTreeTop',@ProcessEndDate=@date,@ProcessedRows = @rows,@insert_new_record=0
 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Import].[Beta.SetDisplayPreferences]'
GO
ALTER PROCEDURE [Profile.Import].[Beta.SetDisplayPreferences]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	select m.NodeID, p.Property, (case when p.n=3 then -1 else v.NodeID end) ViewSecurityGroup
		into #NodeProperty
		from [User.Account].[User] u, [Profile.Import].[Beta.DisplayPreference] d, 
			[RDF.Stage].InternalNodeMap m, [RDF.Stage].InternalNodeMap v, (
				select 0 n, [RDF.].fnURI2NodeID('http://vivoweb.org/ontology/core#authorInAuthorship') Property
				union all
				select 1 n, [RDF.].fnURI2NodeID('http://vivoweb.org/ontology/core#awardOrHonor') Property
				union all
				select 2 n, [RDF.].fnURI2NodeID('http://vivoweb.org/ontology/core#overview') Property
				union all
				select 3 n, [RDF.].fnURI2NodeID('http://profiles.catalyst.harvard.edu/ontology/prns#mainImage') Property
			) p
		where u.PersonID = d.PersonID
			and m.Class = 'http://xmlns.com/foaf/0.1/Person'
			and m.InternalType = 'Person'
			and m.InternalID = cast(u.PersonID as nvarchar(50))
			and v.Class = 'http://profiles.catalyst.harvard.edu/ontology/prns#User'
			and v.InternalType = 'User'
			and v.InternalID = cast(u.UserID as nvarchar(50))
			and ( (p.n=0 and d.ShowPublications='N') or (p.n=1 and d.ShowAwards='N') or (p.n=2 and d.ShowNarrative='N') or (p.n=3 and d.ShowPhoto='Y') )
	create unique clustered index idx_np on #NodeProperty (NodeID, Property)

	insert into [RDF.Security].NodeProperty (NodeID, Property, ViewSecurityGroup)
		select NodeID, Property, ViewSecurityGroup
			from #NodeProperty a
			where not exists (
				select *
				from [RDF.Security].NodeProperty s
				where a.NodeID = s.NodeID and a.Property = s.Property
			)

	update t
		set t.ViewSecurityGroup = n.ViewSecurityGroup
		from #NodeProperty n, [RDF.].Triple t
		where n.NodeID = t.Subject and n.Property = t.Predicate
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Profile.Cache].[Concept.Mesh.UpdateJournal]'
GO
ALTER PROCEDURE [Profile.Cache].[Concept.Mesh.UpdateJournal]
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @ErrMsg nvarchar(4000), @ErrSeverity int,@proc VARCHAR(200),@date DATETIME,@auditid UNIQUEIDENTIFIER,@rows BIGINT 
	SELECT @proc = OBJECT_NAME(@@PROCID),@date=GETDATE() 	
	EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@proc,@ProcessStartDate=@date,@insert_new_record=1

 
	;WITH a AS (
		SELECT m.DescriptorName, g.MedlineTA, max(g.JournalTitle) JournalTitle, sum(Weight) Weight
		FROM [Profile.Data].[Publication.PubMed.General] g
			INNER JOIN (
				SELECT m.DescriptorName, m.PMID, max(case when MajorTopicYN = 'Y' then 1 else 0.25 end) Weight
				FROM [Profile.Data].[Publication.PubMed.Mesh] m
					INNER JOIN [Profile.Data].[Publication.Entity.InformationResource] e
						on m.PMID = e.PMID AND e.IsActive = 1
				GROUP BY m.DescriptorName, m.PMID
			) m ON g.PMID = m.PMID
		GROUP BY m.DescriptorName, g.MedlineTA
	), b AS (
		SELECT DescriptorName, COUNT(*) NumJournals
		FROM a
		GROUP BY DescriptorName
	), c AS (
		SELECT a.DescriptorName MeshHeader, 
			ROW_NUMBER() OVER (PARTITION BY a.DescriptorName ORDER BY Weight DESC, a.MedlineTA) SortOrder,
			a.MedlineTA Journal,
			a.JournalTitle,
			a.Weight,
			b.NumJournals
		FROM a INNER JOIN b ON a.DescriptorName = b.DescriptorName
	)
	SELECT *
		INTO #ConceptMeshJournal
		FROM c
		WHERE SortOrder <= 10

	CREATE UNIQUE CLUSTERED INDEX idx_ms ON #ConceptMeshJournal (MeshHeader, SortOrder)

	BEGIN TRY
		BEGIN TRAN
			TRUNCATE TABLE [Profile.Cache].[Concept.Mesh.Journal]
			INSERT INTO [Profile.Cache].[Concept.Mesh.Journal] (MeshHeader, SortOrder, Journal, JournalTitle, Weight, NumJournals)
				SELECT MeshHeader, SortOrder, Journal, JournalTitle, Weight, NumJournals
				FROM #ConceptMeshJournal
			SELECT @rows = @@ROWCOUNT
		COMMIT
	END TRY
	BEGIN CATCH
		--Check success
		IF @@TRANCOUNT > 0  ROLLBACK
		SELECT @date=GETDATE()
		EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@proc,@ProcessEndDate=@date,@error = 1,@insert_new_record=0
		--Raise an error with the details of the exception
		SELECT @ErrMsg = ERROR_MESSAGE(), @ErrSeverity = ERROR_SEVERITY()
		RAISERROR(@ErrMsg, @ErrSeverity, 1)
	END CATCH
 
	SELECT @date=GETDATE()
	EXEC [Profile.Cache].[Process.AddAuditUpdate] @auditid=@auditid OUTPUT,@ProcessName =@proc,@ProcessEndDate=@date,@ProcessedRows = @rows,@insert_new_record=0
 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [RDF.].[SetNodePropertySecurity]'
GO
ALTER PROCEDURE [RDF.].[SetNodePropertySecurity]
	@NodeID bigint,
	@PropertyID bigint = NULL,
	@PropertyURI varchar(400) = NULL,
	@ViewSecurityGroup bigint
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
 
	SELECT @NodeID = NULL WHERE @NodeID = 0
	SELECT @PropertyID = NULL WHERE @PropertyID = 0

	IF (@PropertyID IS NULL) AND (@PropertyURI IS NOT NULL)
		SELECT @PropertyID = [RDF.].fnURI2NodeID(@PropertyURI)

	-- If node+property, then save setting so that it does
	-- not get overwritten through data loads
	IF (@NodeID IS NOT NULL) AND (@PropertyID IS NOT NULL) AND (@ViewSecurityGroup IS NOT NULL)
	BEGIN
		-- Save setting
		UPDATE [RDF.Security].NodeProperty
			SET ViewSecurityGroup = @ViewSecurityGroup
			WHERE NodeID = @NodeID AND Property = @PropertyID
		INSERT INTO [RDF.Security].NodeProperty (NodeID, Property, ViewSecurityGroup)
			SELECT @NodeID, @PropertyID, @ViewSecurityGroup
			WHERE NOT EXISTS (
				SELECT *
				FROM [RDF.Security].NodeProperty
				WHERE NodeID = @NodeID AND Property = @PropertyID
			)
		-- Update existing triples
		UPDATE [RDF.].Triple
			SET ViewSecurityGroup = @ViewSecurityGroup
			WHERE Subject = @NodeID AND Predicate = @PropertyID
		-- Change ViewSecurityGroup of object nodes to be at least as permissive as the triples
		UPDATE n
			SET n.ViewSecurityGroup = t.v
			FROM [RDF.].[Node] n
				INNER JOIN (
					SELECT NodeID, MAX(v) v
					FROM (
						SELECT n.NodeID, n.ViewSecurityGroup,
							(CASE	WHEN t.ViewSecurityGroup < 0 AND n.ViewSecurityGroup > 0 THEN -1
									WHEN t.ViewSecurityGroup < 0 AND n.ViewSecurityGroup < t.ViewSecurityGroup THEN t.ViewSecurityGroup
									WHEN t.ViewSecurityGroup > 0 AND n.ViewSecurityGroup > 0 AND t.ViewSecurityGroup <> n.ViewSecurityGroup THEN -20
									WHEN t.ViewSecurityGroup > 0 AND n.ViewSecurityGroup < -20 THEN -20
									ELSE n.ViewSecurityGroup END) v
						FROM [RDF.].[Triple] t
							INNER JOIN [RDF.].[Node] n ON t.Object = n.NodeID
						WHERE t.Subject = @NodeID AND t.Predicate = @PropertyID
					) t
					WHERE ViewSecurityGroup <> v
					GROUP BY NodeID
				) t
				ON n.NodeID = t.NodeID
	END
 
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Data].[vwPublication.Entity.General]'
GO
CREATE VIEW [Profile.Data].[vwPublication.Entity.General] AS
		SELECT e.EntityID, g.MedlineTA, g.JournalTitle Journal, g.Authors
			FROM [Profile.Data].[vwPublication.Entity.InformationResource] e, [Profile.Data].[Publication.PubMed.General] g
			WHERE e.pmid = g.pmid AND e.pmid IS NOT NULL AND e.IsActive = 1
		UNION ALL
		SELECT e.EntityID, null MedlineTA, g.PubTitle Journal, g.Authors
			FROM [Profile.Data].[vwPublication.Entity.InformationResource] e, [Profile.Data].[Publication.MyPub.General] g
			WHERE e.mpid = g.mpid AND e.pmid IS NULL AND e.MPID IS NOT NULL AND e.IsActive = 1
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Data].[vwPublication.Entity.Concept.MinorTopicList]'
GO
CREATE VIEW [Profile.Data].[vwPublication.Entity.Concept.MinorTopicList] AS
	SELECT EntityID, SubjectAreaList
	FROM (
		SELECT e.EntityID, substring((
			SELECT '; '+t.DescriptorName
			FROM (
				SELECT m.DescriptorName
				FROM [Profile.Data].[Publication.PubMed.Mesh] m
				WHERE e.pmid = m.pmid
				GROUP BY m.DescriptorName
				HAVING MAX(MajorTopicYN)='N'
			) t
			ORDER BY t.DescriptorName
			FOR XML PATH(''), TYPE
			).value('(./text())[1]','nvarchar(max)'),3,99999) SubjectAreaList
		FROM [Profile.Data].[vwPublication.Entity.InformationResource] e
		WHERE e.IsActive = 1
	) t
	WHERE SubjectAreaList IS NOT NULL
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Data].[vwPublication.Entity.Concept.MajorTopicList]'
GO
CREATE VIEW [Profile.Data].[vwPublication.Entity.Concept.MajorTopicList] AS
	SELECT EntityID, SubjectAreaList
	FROM (
		SELECT e.EntityID, substring((
			SELECT '; '+t.DescriptorName
			FROM (
				SELECT m.DescriptorName
				FROM [Profile.Data].[Publication.PubMed.Mesh] m
				WHERE e.pmid = m.pmid
				GROUP BY m.DescriptorName
				HAVING MAX(MajorTopicYN)='Y'
			) t
			ORDER BY t.DescriptorName
			FOR XML PATH(''), TYPE
			).value('(./text())[1]','nvarchar(max)'),3,99999) SubjectAreaList
		FROM [Profile.Data].[vwPublication.Entity.InformationResource] e
		WHERE e.IsActive = 1
	) t
	WHERE SubjectAreaList IS NOT NULL
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Profile.Data].[vwPublication.Entity.Concept]'
GO
CREATE VIEW [Profile.Data].[vwPublication.Entity.Concept] AS
	SELECT t.EntityID, d.DescriptorUI, t.DescriptorName, hasSubjectAreaWeight, subjectAreaForWeight
	FROM (
		SELECT e.EntityID, m.DescriptorName,
			max(case when MajorTopicYN='N' then 0.25 else 1.0 end) hasSubjectAreaWeight,
			max(case when MajorTopicYN='N' then 0.25*e.YearWeight else e.YearWeight end) subjectAreaForWeight
		FROM [Profile.Data].[vwPublication.Entity.InformationResource] e, [Profile.Data].[Publication.PubMed.Mesh] m
		WHERE e.pmid = m.pmid AND e.pmid IS NOT NULL AND e.IsActive = 1
		GROUP BY e.EntityID, m.DescriptorName
	) t, [Profile.Data].[Concept.Mesh.Descriptor] d
	WHERE t.DescriptorName = d.DescriptorName
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Framework.].[vwBufferDatabases]'
GO
CREATE VIEW [Framework.].[vwBufferDatabases] AS
	SELECT (CASE WHEN database_id = 32767 THEN 'ResourceDb' ELSE DB_NAME(database_id) END) DatabaseName, 
			BufferPageCount/128.0 BufferMB, BufferPageCount, database_id
		FROM (
			SELECT database_id, count(*) BufferPageCount
			FROM sys.dm_os_buffer_descriptors
			GROUP BY database_id
		) t
	--DBCC FREEPROCCACHE
	--DBCC DROPCLEANBUFFERS
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [Framework.].[vwBufferObjects]'
GO
CREATE VIEW [Framework.].[vwBufferObjects] AS
	SELECT OBJECT_SCHEMA_NAME(t.object_id) SchemaName, OBJECT_NAME(t.object_id) ObjectName, i.name IndexName, 
			i.type_desc IndexType, t.BufferPageCount/128.0 BufferMB, t.BufferPageCount, t.object_id, t.index_id
		FROM (
				SELECT p.object_id, p.index_id, count(*) BufferPageCount
				FROM sys.dm_os_buffer_descriptors b
					INNER JOIN sys.allocation_units a
						ON b.allocation_unit_id = a.allocation_unit_id
					INNER JOIN sys.partitions p
						ON a.container_id = p.hobt_id
				WHERE b.database_id = db_id()
				GROUP BY p.object_id, p.index_id
			) t
			LEFT OUTER JOIN sys.indexes i
				ON i.object_id = t.object_id AND i.index_id = t.index_id
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Altering [Framework.].[LICENCE]'
GO
ALTER PROCEDURE [Framework.].[LICENCE]
AS
BEGIN
PRINT 
'
Copyright (c) 2008-2013 by the President and Fellows of Harvard College. All rights reserved.  Profiles Research Networking Software was developed under the supervision of Griffin M Weber, MD, PhD., and Harvard Catalyst: The Harvard Clinical and Translational Science Center, with support from the National Center for Research Resources and Harvard University.
 
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
	* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
	* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
	* Neither the name "Harvard" nor the names of its contributors nor the name "Harvard Catalyst" may be used to endorse or promote products derived from this software without specific prior written permission.
 
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER (PRESIDENT AND FELLOWS OF HARVARD COLLEGE) AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
'
END
GO
IF @@ERROR<>0 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT=0 BEGIN INSERT INTO #tmpErrors (Error) SELECT 1 BEGIN TRANSACTION END
GO
PRINT N'Creating [History.Framework].[ResolveURL]'
GO
CREATE PROCEDURE [History.Framework].[ResolveURL]
@ApplicationName VARCHAR (1000)='', @param1 VARCHAR (1000)='', @param2 VARCHAR (1000)='', @param3 VARCHAR (1000)='', @param4 VARCHAR (1000)='', @param5 VARCHAR (1000)='', @param6 VARCHAR (1000)='', @param7 VARCHAR (1000)='', @param8 VARCHAR (1000)='', @param9 VARCHAR (1000)='', @SessionID UNIQUEIDENTIFIER=null, @ContentType VARCHAR (255)=null, @Resolved BIT OUTPUT, @ErrorDescription VARCHAR (MAX) OUTPUT, @ResponseURL VARCHAR (1000) OUTPUT, @ResponseContentType VARCHAR (255) OUTPUT, @ResponseStatusCode INT OUTPUT, @ResponseRedirect BIT OUTPUT, @ResponseIncludePostData BIT OUTPUT
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	
	-- By default we were not able to resolve the URL
	SELECT @Resolved = 0

	-- Load param values into a table
	DECLARE @params TABLE (id int, val varchar(1000))
	INSERT INTO @params (id, val) VALUES (1, @param1)
	INSERT INTO @params (id, val) VALUES (2, @param2)
	INSERT INTO @params (id, val) VALUES (3, @param3)
	INSERT INTO @params (id, val) VALUES (4, @param4)
	INSERT INTO @params (id, val) VALUES (5, @param5)
	INSERT INTO @params (id, val) VALUES (6, @param6)
	INSERT INTO @params (id, val) VALUES (7, @param7)
	INSERT INTO @params (id, val) VALUES (8, @param8)
	INSERT INTO @params (id, val) VALUES (9, @param9)

	DECLARE @MaxParam int
	SELECT @MaxParam = 0
	SELECT @MaxParam = MAX(id) FROM @params WHERE val > ''

	DECLARE @TabParam int
	SELECT @TabParam = 3

	DECLARE @REDIRECTPAGE VARCHAR(255)
	
	SELECT @REDIRECTPAGE = '~/history/default.aspx'

	-- Return results
	IF (@ErrorDescription IS NULL)
	BEGIN
	
		if(@Param1='list')
		BEGIN
			SELECT @Resolved = 1,
				@ErrorDescription = '',
				@ResponseURL = @REDIRECTPAGE + '?tab=list'
		END						

		if(@Param1='type')
		BEGIN
			SELECT @Resolved = 1,
				@ErrorDescription = '',
				@ResponseURL = @REDIRECTPAGE  + '?tab=type'									
		END		
	

set	@ResponseContentType =''
set	@ResponseStatusCode  =''
set	@ResponseRedirect =0
set	@ResponseIncludePostData =0



				
	END





END
GO

IF EXISTS (SELECT * FROM #tmpErrors) ROLLBACK TRANSACTION
GO
IF @@TRANCOUNT>0 BEGIN
PRINT 'The database update succeeded'
COMMIT TRANSACTION
END
ELSE PRINT 'The database update failed'
GO
DROP TABLE #tmpErrors
GO
