#Writes seperate edge list file for each cluster, including only edges within clusters
WriteNetworkFile <- function(curEdges,path,clusters){
  #We have a huge number of node/gene -> cluster mapping (especially at the transcript level)
  #Hashmap is the fastest way to construct this mapping.
  clusterSizes <- sapply(clusters,length)
  numClusters <- length(clusters)
  keys <- do.call(c,clusters)
  values <- do.call(c,lapply(1:numClusters,function(i) rep(i,clusterSizes[i])))
  # dict <- setNames(as.list(values), keys)
  dict <- hashmap::hashmap(keys=keys,values=values)
  
  #Construct data table representable of edge list.Filter for edges within same cluster. 
  #Since all edges are now in the same cluster (ie Node1Cluster = Node2Cluster), use simplfied label cluster
  edgeListWithClusterInfo <- curEdges %>% 
  dplyr::mutate(Node1Cluster=dict[[Node1]],
                Node2Cluster=dict[[Node2]]) %>% 
    dplyr::filter(!is.na(Node1Cluster) & !is.na(Node2Cluster)) %>%
    dplyr::filter(Node1Cluster==Node2Cluster) %>% dplyr::select(Node1,Node2,W,Cluster=Node1Cluster)
  
  edgeListSplitByCluster <- split(edgeListWithClusterInfo,edgeListWithClusterInfo$Cluster)
  
  #Write the edge list files
  for(i in 1:length(edgeListSplitByCluster)){
    data.table::fwrite(edgeListSplitByCluster[[i]] %>% dplyr::select(-Cluster),
                       file = paste0(path,'edgelist_',as.character(i),'.txt'),row.names = F,
                       col.names = F,sep = ' ')
  }
  return(edgeListWithClusterInfo %>% dplyr::select(-Cluster))
}

#Parse all cluster info, and store all clusters as txt files in the level directory specified
#Clusters above min clusterSize are stored
#Clsuters above and below min clusterSize are written in seperate txt files. 
StoreClusterResult <- function(clustersList,path,minClusterSize=3,curLevel){
  #Pass in a cluster file from one network
  ParseClusters <- function(clusterDf){
    indivClusters <- split(clusterDf,clusterDf$Cluster)
    #Return list of genes, each element of the list is a character vector, 
    #specifying the genes within a cluster. 
    indivGenes <- lapply(indivClusters,function(x) as.character(x$Genes))
    return(indivGenes)
  }
  #convert cluster list from multiple networks into a dataframe
  clustersDf <- lapply(clustersList,function(x) data.frame(Cluster = 
                                                            x[[1]],
                                                          Genes = x[[2]]))
  #convert tables to character vectors of genes within a cluster
  allIndivGeneList <- unlist(lapply(clustersDf,function(x) ParseClusters(x)),recursive = F)
  #Find number of genes in each cluster
  clusterSizes <- sapply(allIndivGeneList,length)
  
  overCutoffGeneStrListGmt <- lapply(allIndivGeneList[clusterSizes >= minClusterSize],
                                  function(x) paste(x,collapse = "\t"))
  overCutoffGeneStrListGmt <- lapply(1:length(overCutoffGeneStrList),function(i) paste(
    paste0('level_',curLevel,'_cluster_',i),
    clusterSizes[i],
    overCutoffGeneStrListGmt[i],sep = "\t"))
  overCutoffGeneStrListGmt <- paste(overCutoffGeneStrListGmt,collapse = "\n")
  #Each line of file is a cluster. First column is name of cluster, second column is description, rest are gene IDS.
  overCutOffGmtFile <- file(paste0(path,'overCutOffClusters.gmt'),'w')
  write(overCutoffGeneStrListGmt,overCutOffGmtFile,ncolumns = 1,append = F)
  close(overCutOffGmtFile)
  
  #Space seperated file for easy parsing. each line a cluster
  overCutoffGeneStrList <- paste(lapply(allIndivGeneList[clusterSizes >= minClusterSize],
                                  function(x) paste(x,collapse = " ")),collapse = "\n")
  write(overCutoffGeneStrList,file(paste0(path,'overCutOffClusters.txt'),'w'),ncolumns = 1,append = F)
  
  
  if(any(clusterSizes < minClusterSize)){
    underCutoffGeneStrList <- paste0(lapply(allIndivGeneList[clusterSizes < minClusterSize],
                                            function(x) paste(x,collapse = " ")),collapse = "\n")
    underCutOffFile <- file(paste0(path,'underCutOffClusters.txt'),'w')
    write(underCutoffGeneStrList,underCutOffFile,ncolumns = 1,append = F)
    close(underCutOffFile)
    
  }
  #Return clusters as a list of character vectors, to be used to construct edge file. 
  return(allIndivGeneList[clusterSizes > minClusterSize])
}

#Main function, pass in path to edge lists (from corr matrix), and output directory.
RunLouvainRecursive <- function(initialEdgeListPath,outDirectory){
  source('invoke_louvain.R')
  library(parallel)
  library(data.table)
  library(dplyr)
  library(hashmap)
  system(paste0('mkdir -p ',outDirectory))
  numCores = 40
  maxlevels <- 20
  curLevel <- 0
  #load initialEdgeList into memory, 
  initialEdges <- data.table::fread(initialEdgeListPath,
                                    col.names = c('Node1','Node2','W'),
                                    showProgress = F)
  numClusters <- 0
  clusterSizes <- vector(mode = 'list',length = maxlevels)
  while(curLevel <= maxlevels){
    if(curLevel == 0){
      #Specifiy to run Louvain on only 1 edge file.
      allEdgeLists <- list(initialEdgeListPath)
      curEdges <- initialEdges
      curLevel <- curLevel + 1
    }else{
      #Subsequent iterations, get path to all edge files, which were stored in previous iteration.
      edgeListPath <- paste0(outDirectory,'/level_',as.character(curLevel-1),'/edges/')
      #get path to each individual edge file
      allEdgeLists <- lapply(dir(edgeListPath),function(x) paste0(edgeListPath,x))
    }
    print(paste('Running Level:',curLevel))
    #Run Louvain on all the edge files for current level (writting in prev iteration)
    #Compute in parallel, by invoke number of cores edge to number of edge lists (but less than limit)
    clustersList <- mclapply(allEdgeLists,
                             function(x) run_louvain(x),
                             mc.cores = min(c(length(allEdgeLists),numCores)))
    
    #Store cluster results of current level
    levelPath <- paste0(outDirectory,'/level_',as.character(curLevel))
    system(paste0('mkdir -p ',levelPath))
    system(paste0('mkdir -p ',levelPath,'/clusters'))
    curLevelParsedClusters <- StoreClusterResult(clustersList,path = paste0(levelPath,'/clusters/'),minClusterSize = 3,curLevel = curLevel)
    clusterSizes[[curLevel]] <- sapply(curLevelParsedClusters,length)
    
    #Write edge file for next level, according to current level clusters.
    #Only do so if there are clusters left to divide. 
    #stop if covergence, non of clusters divided form previous iteration.
    numClusters <- c(numClusters,length(curLevelParsedClusters))
    if(length(curLevelParsedClusters) == 0 | numClusters[curLevel+1] == numClusters[curLevel]){
      return()
    }else{
      system(paste0('mkdir -p ',levelPath,'/edges'))
      #For each remaining clusters(those that fall in clusters above min size), store edges
      curEdges <- WriteNetworkFile(curEdges = curEdges,
                       path = paste0(levelPath,'/edges/'),
                       curLevelParsedClusters)
    }
    print(paste('Num Clusters:',length(curLevelParsedClusters)))
    #Move to next level
    curLevel <- curLevel + 1
  }
  stats <- list(numClusters[-1],clusterSizes[sapply(clusterSizes,!is.null)])
  save(stats,file=paste0(outDirectory,'/stats.rda'))
}
outDirectory <- '/local/data/public/zmx21/zmx21_private/GSK/Louvain_results/CodingMicrogliaGenes'
initialEdgeListPath <- '/local/data/public/zmx21/zmx21_private/GSK/Louvain_Edge_List/CodingGenesEdgeListMicroglia.txt'
RunLouvainRecursive(initialEdgeListPath = initialEdgeListPath,outDirectory = outDirectory)

outDirectory <- '/local/data/public/zmx21/zmx21_private/GSK/Louvain_results/AllMicrogliaGene'
initialEdgeListPath <- '/local/data/public/zmx21/zmx21_private/GSK/Louvain_Edge_List/AllGenesEdgeListMicroglia.txt'
RunLouvainRecursive(initialEdgeListPath = initialEdgeListPath,outDirectory = outDirectory)